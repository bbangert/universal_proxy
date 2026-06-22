defmodule UniversalProxy.FirmwareUpdate do
  @moduledoc """
  Host-side façade and wiring for the firmware update flow.

  The library (`UniversalProxy.FirmwareUpdate.{GithubClient, Signature,
  Updater, Fwup, Supervisor}`) is intentionally host-agnostic. This
  module is the seam where host-specific glue lives:

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

  alias UniversalProxy.FirmwareUpdate.{ConfigStore, Updater}

  # Aliased separately because the unaliased `Supervisor` below refers
  # to the stdlib supervisor (used by start_link/1).
  alias UniversalProxy.FirmwareUpdate.Supervisor, as: LibSupervisor

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
        }
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
      devpath_fn: &__MODULE__.devpath/0
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
      Updater.state(Updater)
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

      case Updater.update_config(Updater, propagated) do
        :ok ->
          :ok

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
  Resolves the `(fw_asset, sig_asset)` from a release's asset list.

  The matcher contract is `(tag, assets) -> {:ok, fw, sig} | {:error, reason}`.
  Filename pattern: `universal_proxy_<target>.fw` + `.fw.sig`. Target
  comes from `Nerves.Runtime.KV[\"nerves_fw_platform\"]`, falling back
  to the compile-time `Mix.target/0`.
  """
  @spec match_asset(String.t(), [map()]) ::
          {:ok, map(), map() | nil} | {:error, :no_fw_asset}
  def match_asset(_tag_name, assets) when is_list(assets) do
    target = current_target()
    fw_name = "universal_proxy_#{target}.fw"
    sig_name = fw_name <> ".sig"

    fw_asset = Enum.find(assets, fn a -> a.name == fw_name end)
    sig_asset = Enum.find(assets, fn a -> a.name == sig_name end)

    case fw_asset do
      nil -> {:error, :no_fw_asset}
      asset -> {:ok, with_download_url(asset), with_download_url(sig_asset)}
    end
  end

  # Use the public browser_download_url for the actual fetch. The
  # GitHub API `:url` 302-redirects to a signed S3 URL; Req forwards
  # the Authorization: Bearer header across redirects by default,
  # which would leak the operator token to GitHub's S3 host. The
  # browser URL is a direct S3 download that doesn't need (or want)
  # the bearer.
  defp with_download_url(nil), do: nil

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

  # -- Private --

  defp host_mode?, do: @target == "host"

  defp current_target do
    if Code.ensure_loaded?(Nerves.Runtime.KV) and
         function_exported?(Nerves.Runtime.KV, :get_active, 1) do
      Nerves.Runtime.KV.get_active("nerves_fw_platform") || @target
    else
      @target
    end
  end
end
