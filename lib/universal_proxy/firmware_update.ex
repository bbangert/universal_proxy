defmodule UniversalProxy.FirmwareUpdate do
  @moduledoc """
  Host-side façade and wiring for the firmware update flow.

  The update pipeline itself lives in the external `nerves_github_updater`
  hex library (`NervesGithubUpdater.{GithubClient, Signature, Updater,
  Fwup, Supervisor}`), which is intentionally host-agnostic. This
  module is the host facade wiring it into the app — the seam where
  host-specific glue lives:

    * Wiring config from `ConfigStore` into the library `Supervisor`.
    * Mapping target firmware to GitHub assets
      (`universal_proxy_<target>.fw`).
    * Providing the reboot and devpath functions the library calls back
      into after a successful flash.
    * Single entry point for runtime configuration changes (SSH/IEx
      pattern from interview Q6).

  ## SSH / IEx configuration overrides

      iex> UniversalProxy.FirmwareUpdate.update_config(repo: "myfork/proxy")
      :ok
      iex> UniversalProxy.FirmwareUpdate.update_config(verification_required: true)
      :ok
      iex> UniversalProxy.FirmwareUpdate.check()
      :ok  # next check uses the new repo

  Persistence in `ConfigStore` is the source of truth. If the live
  Updater rejects a propagated key (e.g. an immutable wiring opt
  slipped through), we log a warning but keep the DETS write — the
  authoritative state is what survives a restart.
  """

  require Logger

  alias UniversalProxy.FirmwareUpdate.{ConfigStore, Poller}
  alias NervesGithubUpdater.Updater

  # Aliased separately because the unaliased `Supervisor` below refers
  # to the stdlib supervisor (used by start_link/1).
  alias NervesGithubUpdater.Supervisor, as: LibSupervisor

  @compile {:no_warn_undefined, [Nerves.Runtime, Nerves.Runtime.KV]}

  @pubsub UniversalProxy.PubSub
  @topic "firmware_update:progress"

  @target Mix.target() |> to_string()

  # -- Public child_spec / start_link --

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  def start_link(_opts) do
    Supervisor.start_link(
      [
        ConfigStore,
        %{
          id: LibSupervisor,
          start: {__MODULE__, :start_library, []},
          type: :supervisor
        },
        # Last in rest_for_one: the Updater must exist before the poller
        # can ask it to check. Nothing else schedules checks — the library
        # arms no timers and does none at boot.
        Poller
      ],
      strategy: :rest_for_one,
      name: __MODULE__
    )
  end

  @doc false
  def start_library do
    snap = ConfigStore.snapshot()

    LibSupervisor.start_link(
      owner_repo: snap.repo,
      github_token: snap.github_token,
      public_key: snap.public_key,
      verification_required: snap.verification_required,
      asset_matcher: &__MODULE__.match_asset/2,
      pubsub: @pubsub,
      pubsub_topic: @topic,
      download_dir: download_dir(),
      reboot_fn: &__MODULE__.reboot/0,
      devpath_fn: &__MODULE__.devpath/0,
      kv_get: &__MODULE__.kv_get/1,
      kv_put: &__MODULE__.kv_put/2,
      target_fn: &__MODULE__.current_target/0,
      current_version_fn: &__MODULE__.current_version/0
    )
  end

  # -- Public API --

  @doc "Topic LiveViews subscribe to for `{:fw_update_progress, payload}`."
  def topic, do: @topic

  @doc "PubSub module used by the firmware-update flow."
  def pubsub, do: @pubsub

  @doc """
  Kick off an update check. On host (`Mix.target() == :host`) returns
  `{:error, :host_mode}` since there's no device to update.
  """
  @spec check() :: :ok | {:error, :host_mode}
  def check do
    if host_mode?() do
      {:error, :host_mode}
    else
      Updater.check(Updater)
    end
  end

  @spec install_latest() :: :ok | {:error, :host_mode | :no_release_cached | :busy}
  def install_latest do
    if host_mode?() do
      {:error, :host_mode}
    else
      Updater.install_latest(Updater)
    end
  end

  @doc "Returns the live Updater snapshot for LiveView mount."
  @spec state() :: map()
  def state do
    if host_mode?() do
      %{
        phase: :idle,
        pct: nil,
        message: nil,
        last_error: nil,
        last_release: nil,
        verification_required: ConfigStore.verification_required?()
      }
    else
      # Flash-safe: the Updater deliberately blocks its whole loop while
      # fwup writes the firmware (documented design), so a LiveView
      # mounting mid-flash would exit at the 5 s default call timeout —
      # render a busy-shaped snapshot for that case. Only the timeout
      # means "flash in progress"; any other exit (e.g. :noproc while
      # the Updater restarts) must not masquerade as installing.
      try do
        Updater.state(Updater)
      catch
        :exit, {:timeout, {GenServer, :call, _}} ->
          %{
            phase: :installing,
            pct: nil,
            message: "Installing firmware…",
            last_error: nil,
            last_release: nil,
            verification_required: ConfigStore.verification_required?()
          }

        :exit, reason ->
          Logger.warning("FirmwareUpdate.state: Updater unavailable: #{inspect(reason)}")

          %{
            phase: :idle,
            pct: nil,
            message: nil,
            last_error: nil,
            last_release: nil,
            verification_required: ConfigStore.verification_required?()
          }
      end
    end
  end

  @doc """
  Persist + propagate config changes.

  `ConfigStore.put/1` is the source of truth; the live Updater is
  updated as a best-effort follow-up. If propagation fails (e.g. an
  immutable key slipped through), the warning is logged but `:ok` is
  still returned — the DETS write survives across restarts.
  """
  @spec update_config(keyword()) :: :ok | {:error, term()}
  def update_config(updates) when is_list(updates) do
    with :ok <- ConfigStore.put(updates) do
      # Always propagate the post-sanitization snapshot, not the raw
      # input. Two reasons:
      # 1. ConfigStore drops invalid values (empty repo, wrong-sized
      #    pubkey) — the live Updater must see the same sanitized
      #    state, not the bad user input.
      # 2. The user-facing key is `:repo`; the Updater opts use
      #    `:owner_repo`. Translating here keeps the SSH/IEx surface
      #    clean while still reaching the live process.
      snap = ConfigStore.snapshot()

      propagated = [
        owner_repo: snap.repo,
        github_token: snap.github_token,
        public_key: snap.public_key,
        verification_required: snap.verification_required
      ]

      # Flash-safe like `state/0`: a flash in progress blocks the
      # Updater's loop past the call timeout — report `{:error, :busy}`
      # for that case only. Any other exit (e.g. :noproc during an
      # Updater restart) is a best-effort propagation failure like the
      # `{:error, reason}` branch below: logged, but `:ok` — the DETS
      # write above already landed and survives restart.
      result =
        try do
          Updater.update_config(Updater, propagated)
        catch
          :exit, {:timeout, {GenServer, :call, _}} -> {:error, :busy}
          :exit, reason -> {:error, {:updater_unavailable, reason}}
        end

      case result do
        :ok ->
          :ok

        {:error, :busy} ->
          Logger.warning(
            "FirmwareUpdate.update_config: live Updater busy (flash in progress); " <>
              "DETS persist applied, restart picks it up"
          )

          {:error, :busy}

        {:error, reason} ->
          Logger.warning(
            "FirmwareUpdate.update_config: propagation to live Updater returned " <>
              "#{inspect(reason)} (DETS persist still applied; restart picks it up)"
          )

          :ok
      end
    end
  end

  @doc """
  Resolves the firmware asset from a release's asset list.

  The matcher contract is `(tag, assets) -> {:ok, fw_asset} | {:error, reason}`
  (legacy/unverified path only — the manifest path resolves its target
  asset itself). Filename pattern: `universal_proxy_<target>.fw`.
  Target comes from `Nerves.Runtime.KV["nerves_fw_platform"]`, falling
  back to the compile-time `Mix.target/0`.
  """
  @spec match_asset(String.t(), [map()]) :: {:ok, map()} | {:error, :no_fw_asset}
  def match_asset(_tag_name, assets) when is_list(assets) do
    target = current_target()
    fw_name = "universal_proxy_#{target}.fw"

    case Enum.find(assets, fn a -> a.name == fw_name end) do
      nil -> {:error, :no_fw_asset}
      asset -> {:ok, with_download_url(asset)}
    end
  end

  # Use the public browser_download_url for the actual fetch: it's a
  # direct public download that needs no auth at all, the simplest
  # correct choice given v0.1 is public-repos-only. The GitHub API
  # asset `:url` route would work too, but needs an
  # `accept: application/octet-stream` + Bearer flow and is only
  # needed for private repos.
  defp with_download_url(%{browser_download_url: url} = asset) when is_binary(url) do
    %{asset | url: url}
  end

  defp with_download_url(asset), do: asset

  @doc false
  def reboot do
    if Code.ensure_loaded?(Nerves.Runtime) and
         function_exported?(Nerves.Runtime, :reboot, 0) and File.dir?("/data") do
      Nerves.Runtime.reboot()
    end

    :ok
  end

  @doc false
  def devpath do
    cond do
      Code.ensure_loaded?(Nerves.Runtime.KV) and
          function_exported?(Nerves.Runtime.KV, :get, 1) ->
        # nerves_fw_devpath is a global (non-prefixed) U-Boot variable, so it
        # must be read with get/1 — get_active/1 prepends the active partition
        # ("a."/"b.") and finds nothing, yielding :missing_devpath at flash time.
        Nerves.Runtime.KV.get("nerves_fw_devpath") ||
          Nerves.Runtime.KV.get("nerves_fw_destination")

      true ->
        nil
    end
  end

  @doc false
  def download_dir do
    if File.dir?("/data") do
      "/data"
    else
      Path.join([File.cwd!(), "_build", "firmware_update"])
    end
  end

  @doc false
  def kv_get(key) do
    if Code.ensure_loaded?(Nerves.Runtime.KV) and function_exported?(Nerves.Runtime.KV, :get, 1) do
      Nerves.Runtime.KV.get(key)
    else
      nil
    end
  end

  @doc false
  def kv_put(key, value) do
    if Code.ensure_loaded?(Nerves.Runtime.KV) and
         function_exported?(Nerves.Runtime.KV, :put, 2) do
      # Return KV.put's real result (`:ok | {:error, any()}`) — the
      # Updater logs a failed rollback-counter write, so swallowing the
      # error here would make that log dead code on device.
      Nerves.Runtime.KV.put(key, value)
    else
      :ok
    end
  end

  @doc false
  def current_version do
    if Code.ensure_loaded?(Nerves.Runtime.KV) and
         function_exported?(Nerves.Runtime.KV, :get_active, 1) do
      Nerves.Runtime.KV.get_active("nerves_fw_version")
    else
      nil
    end
  end

  @doc false
  def current_target do
    if Code.ensure_loaded?(Nerves.Runtime.KV) and
         function_exported?(Nerves.Runtime.KV, :get_active, 1) do
      Nerves.Runtime.KV.get_active("nerves_fw_platform") || @target
    else
      @target
    end
  end

  # -- Private --

  defp host_mode?, do: @target == "host"
end
