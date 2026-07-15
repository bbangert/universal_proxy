defmodule UniversalProxy.FirmwareUpdate.Updater do
  @moduledoc """
  Firmware update orchestration GenServer.

  Library-shape: no host dependencies. All wiring (PubSub module,
  topic, download dir, fwup devpath/task, GithubClient module,
  asset-matcher closure) comes through `start_link/1` opts.

  ## State machine

      :idle ─→ :checking ─→ :idle
      :idle ─→ :downloading ─→ :flashing ─→ :idle                    (legacy, unverified)
      :idle ─→ :verifying ─→ :downloading ─→ :flashing ─→ :idle      (manifest, verified)
                    any phase above ↘ :error ↗ (next check/1 clears to :idle)

  Every phase transition broadcasts `{:fw_update_progress, payload}`
  on the configured PubSub topic. `:error` clears to `:idle` on the
  next `check/1`. There is no retry, no cancel, no HTTP-range resume
  (conservative error policy — see plan Q7).

  ## Progress snapshot caveat

  `state.pct` is updated on phase transitions only (so a `state/1`
  snapshot reports `0` at the start of `:downloading` / `:flashing`).
  Intermediate per-byte progress is broadcast via PubSub but does
  not mutate the GenServer state — the install runs inside a
  single `handle_info/2` that blocks the GenServer, so routing
  progress through self-messages would just buffer them all until
  the install completes. A subscriber that reads a fresh `state/1`
  snapshot mid-install therefore sees a stale `pct` for the brief
  window until the next PubSub event lands and corrects it.

  ## Conditional verification

  When opts `:verification_required` is `false` (v1 default), the
  install flow is the legacy path: `asset_matcher.(tag, assets)`
  resolves a single firmware asset, which is downloaded unverified and
  flashed (`:downloading → :flashing`, no `:verifying` phase). A
  `Logger.warning` fires on every such install so the unverified
  state is auditable in `RingLogger`.

  When `:verification_required` is `true`, the flow is the manifest
  path (`:verifying → :downloading → :flashing`) — see "## Manifest
  verification" below.

  ## Downgrade gate

  Before either path runs, `release.tag_name` is compared against
  `:current_version_fn.()` via `VersionCompare.compare/2`. A `:lt`
  result (release older than the running firmware) is refused unless
  `:allow_downgrade` is `true`. This is belt-and-braces: the manifest
  counter (see below) is the primary rollback control and is the only
  check that applies on the manifest path; this semver check also
  guards the legacy (unverified) path, which has no counter at all.
  `:gt`, `:eq`, `:missing`, and `:incomparable` all proceed.

  ## Manifest verification

  Wire contract: `docs/manifest-format.md`. Summary of the device-side
  pipeline (entered when `:verification_required` is `true`):

    1. Transition to `:verifying`.
    2. Download `release-manifest.json` + `release-manifest.sig` from
       the release assets (missing either ⇒ `:missing_manifest` /
       `:missing_manifest_signature`).
    3. `sig_mod.verify_manifest(manifest_bytes, sig_bytes, pubkey)` —
       signed message is `sha512(manifest_bytes)`, not the raw bytes.
    4. `Manifest.parse/1` — schema + version validation.
    5. `Manifest.check_expiry/2` — policy-gated, default off
       (`:enforce_expiry`).
    6. `Manifest.check_counter/2` against `:kv_get.("fw_manifest_counter")`
       — rejects a lower counter (rollback), accepts equal or absent.
    7. `:target_fn.()` resolves the device's Nerves target;
       `Manifest.target/2` looks up its `%{asset, sha256, size}` entry.
    8. Transition to `:downloading`; download the named release asset
       with `expected_sha256` / `expected_size` — the client verifies
       the streamed hash before the atomic rename.
    9. Flash (`:flashing`). On success, `:kv_put.("fw_manifest_counter",
       counter)` **before** reboot — the counter anchor only advances
       once the new firmware is actually on disk.

  Any failure at any step broadcasts `{:fw_update_progress, %{phase:
  :error, ...}}` and resets to `:idle` on the next `check/1`.

  ## Opts

    * `:owner_repo`, `:github_token`, `:public_key` — as before.
    * `:verification_required` (default `false`) — selects legacy vs
      manifest install path (see above).
    * `:channel` (default `:stable`) — forwarded to
      `client.latest_release/2`; `:stable` or `:prerelease`.
    * `:allow_downgrade` (default `false`) — see "Downgrade gate".
    * `:enforce_expiry` (default `false`) — see "Manifest verification".
    * `:kv_get` — `(String.t() -> String.t() | nil)`, reads the
      persisted counter anchor. Missing ⇒ `fn _ -> nil end` (no
      anchor, first-contact trust).
    * `:kv_put` — `(String.t(), String.t() -> :ok)`, persists the new
      counter anchor after a successful flash. Missing ⇒
      `fn _, _ -> :ok end` (no-op — degrades gracefully rather than
      crashing the install on a host/test without Nerves.Runtime.KV).
    * `:target_fn` — `(-> String.t())`, resolves the device's Nerves
      target for the manifest path. Missing ⇒
      `{:error, :missing_target_fn}` (fails the install via the normal
      `fail/3` path; the legacy path never calls it).
    * `:current_version_fn` — `(-> String.t() | nil)`, the device's
      current firmware version for the downgrade gate. Missing ⇒
      `fn -> nil end` (comparison against `nil` is `:missing`, which
      proceeds).
    * `:asset_matcher` — legacy-path only. Contract is `(tag, assets)
      -> {:ok, fw_asset} | {:error, reason}` (no more sig asset — the
      manifest path replaces per-asset signatures entirely).

  ## Test seams

    * `:client` — module implementing `latest_release/2` and
      `download_asset/3` (default `UniversalProxy.FirmwareUpdate.GithubClient`).
    * `:fwup` — module implementing `apply/2` (default
      `UniversalProxy.FirmwareUpdate.Fwup`).
    * `:signature` — module implementing `verify_manifest/3` (default
      `UniversalProxy.FirmwareUpdate.Signature`).
  """

  use GenServer

  require Logger

  alias UniversalProxy.FirmwareUpdate.{Manifest, VersionCompare}

  @manifest_asset "release-manifest.json"
  @manifest_sig_asset "release-manifest.sig"
  @counter_key "fw_manifest_counter"

  @mutable_keys [
    :owner_repo,
    :github_token,
    :public_key,
    :verification_required,
    :asset_matcher,
    :client,
    :fwup,
    :signature,
    :reboot_fn,
    :devpath_fn,
    :channel,
    :allow_downgrade,
    :enforce_expiry,
    :kv_get,
    :kv_put,
    :target_fn,
    :current_version_fn
  ]

  @immutable_keys [
    :pubsub,
    :pubsub_topic,
    :download_dir,
    :fwup_devpath,
    :fwup_task
  ]

  # -- Client API --

  def start_link(opts) do
    server_name = Keyword.get(opts, :name, __MODULE__)

    case server_name do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Kicks off a check for a new release. Returns `:ok` immediately;
  the actual result is broadcast via PubSub.
  """
  @spec check(GenServer.server()) :: :ok
  def check(server \\ __MODULE__) do
    GenServer.cast(server, :check)
  end

  @doc """
  Starts download → (optionally verify) → flash for the most recently
  fetched release. Returns `{:error, :no_release_cached}` if `check/1`
  has not produced a release yet, or `{:error, :busy}` if a phase is
  in flight.
  """
  @spec install_latest(GenServer.server()) :: :ok | {:error, :no_release_cached | :busy}
  def install_latest(server \\ __MODULE__) do
    GenServer.call(server, :install_latest)
  end

  @doc "Synchronous snapshot for a subscriber's initial render."
  @spec state(GenServer.server()) :: map()
  def state(server \\ __MODULE__) do
    GenServer.call(server, :state)
  end

  @doc """
  Update mutable opts. Takes effect for the **next** check/install —
  in-flight operations continue with the opts they started with.

  Returns `:ok | {:error, :immutable | :unknown}`.
  """
  @spec update_config(GenServer.server(), keyword()) ::
          :ok | {:error, :immutable | :unknown}
  def update_config(server \\ __MODULE__, updates) when is_list(updates) do
    GenServer.call(server, {:update_config, updates})
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    download_dir = Keyword.fetch!(opts, :download_dir)
    File.mkdir_p!(download_dir)
    scrub_partials(download_dir)

    state = %{
      phase: :idle,
      pct: nil,
      message: nil,
      last_error: nil,
      last_release: nil,
      etag: nil,
      opts: opts |> Keyword.delete(:name) |> Map.new()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, public_state(state), state}

  def handle_call(:install_latest, _from, state) do
    cond do
      state.phase in [:checking, :downloading, :verifying, :flashing] ->
        {:reply, {:error, :busy}, state}

      is_nil(state.last_release) ->
        {:reply, {:error, :no_release_cached}, state}

      true ->
        # Lock the phase synchronously so a second `install_latest/1`
        # arriving before :do_install is dequeued falls into the
        # :busy branch above instead of enqueuing a duplicate install
        # (and a duplicate reboot). Snapshot opts + release at call
        # time for the same reason — see @moduledoc on the in-flight
        # opts contract. The message is neutral because the next
        # phase differs by path (legacy skips :verifying); the UI
        # treats :downloading/:verifying/:flashing identically anyway.
        new_state =
          transition(
            %{state | last_error: nil},
            :downloading,
            "Starting install…",
            0
          )

        send(self(), {:do_install, state.opts, state.last_release})
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:update_config, updates}, _from, state) do
    case validate_updates(updates) do
      :ok ->
        new_opts = Enum.reduce(updates, state.opts, fn {k, v}, acc -> Map.put(acc, k, v) end)
        {:reply, :ok, %{state | opts: new_opts}}

      err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_cast(:check, %{phase: phase} = state)
      when phase in [:checking, :downloading, :verifying, :flashing] do
    {:noreply, state}
  end

  def handle_cast(:check, state) do
    # Transition to :checking synchronously. A second :check cast
    # arriving before :do_check is dequeued falls into the busy
    # guard above instead of enqueuing a duplicate API call.
    # Snapshot opts here for the same opts-race reason install_latest
    # does — see @moduledoc.
    new_state = transition(%{state | last_error: nil}, :checking, "Checking for updates…")
    send(self(), {:do_check, new_state.opts})
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:do_check, opts}, state) do
    client = client_mod(opts)
    repo = Map.fetch!(opts, :owner_repo)

    client_opts =
      [
        github_token: Map.get(opts, :github_token),
        etag: state.etag,
        channel: Map.get(opts, :channel, :stable)
      ]
      |> maybe_put(:req_options, Map.get(opts, :req_options))

    case client.latest_release(repo, client_opts) do
      {:ok, :not_modified} ->
        {:noreply, transition(state, :idle, "Up to date.")}

      {:ok, %{} = release} ->
        new_state = %{state | last_release: release, etag: release.etag}
        {:noreply, transition(new_state, :idle, "Latest release: #{safe_log(release.tag_name)}")}

      {:error, reason} ->
        {:noreply, fail(state, "Check failed: #{format_error(reason)}", reason)}
    end
  end

  def handle_info({:do_install, _opts, nil}, state), do: {:noreply, state}

  def handle_info({:do_install, opts, release}, state) do
    current = current_version_fn(opts).()
    allow_downgrade = Map.get(opts, :allow_downgrade, false)

    case VersionCompare.compare(release.tag_name, current) do
      :lt when not allow_downgrade ->
        reason = {:downgrade_refused, release.tag_name, current}
        {:noreply, fail(state, "Install failed: #{format_error(reason)}", reason)}

      _ ->
        if Map.get(opts, :verification_required, false) do
          do_manifest_install(state, opts, release)
        else
          do_legacy_install(state, opts, release)
        end
    end
  end

  # -- Private --

  defp do_legacy_install(state, opts, release) do
    matcher = Map.fetch!(opts, :asset_matcher)

    case matcher.(release.tag_name, release.assets) do
      {:ok, fw_asset} ->
        Logger.warning(
          "Firmware install proceeding without signature verification (verification_required=false)"
        )

        client = client_mod(opts)
        download_dir = Map.fetch!(opts, :download_dir)
        fw_path = Path.join(download_dir, "firmware_pending.fw")

        fw_dl =
          client.download_asset(fw_asset.url, fw_path,
            # Intentionally no github_token here: asset URLs from
            # `browser_download_url` are public S3 redirects that
            # don't need (and shouldn't see) the operator bearer.
            expected_size: Map.get(fw_asset, :size, 0),
            progress: &broadcast_progress(state, &1),
            req_options: Map.get(opts, :req_options) || []
          )

        with :ok <- fw_dl,
             {:ok, flashed_state} <- do_flash(state, opts, fw_path) do
          cleanup_partials([fw_path])
          new_state = transition(flashed_state, :idle, "Install complete; rebooting.", 100)
          run_reboot(opts)
          {:noreply, new_state}
        else
          {:error, reason} ->
            cleanup_partials([fw_path])
            {:noreply, fail(state, "Install failed: #{format_error(reason)}", reason)}
        end

      {:error, reason} ->
        {:noreply, fail(state, "No matching firmware asset: #{format_error(reason)}", reason)}
    end
  end

  defp do_manifest_install(state, opts, release) do
    state = transition(state, :verifying, "Verifying release manifest…")

    download_dir = Map.fetch!(opts, :download_dir)
    client = client_mod(opts)
    sig_mod = Map.get(opts, :signature, UniversalProxy.FirmwareUpdate.Signature)
    pubkey = Map.get(opts, :public_key)
    enforce_expiry = Map.get(opts, :enforce_expiry, false)
    kv_get = kv_get_fn(opts)
    kv_put = kv_put_fn(opts)

    manifest_path = Path.join(download_dir, @manifest_asset)
    sig_path = Path.join(download_dir, @manifest_sig_asset)
    fw_path = Path.join(download_dir, "firmware_pending.fw")

    result =
      with {:ok, manifest_asset} <-
             find_release_asset(release.assets, @manifest_asset, :missing_manifest),
           {:ok, sig_asset} <-
             find_release_asset(release.assets, @manifest_sig_asset, :missing_manifest_signature),
           :ok <- download_support_asset(client, manifest_asset, manifest_path, opts),
           :ok <- download_support_asset(client, sig_asset, sig_path, opts),
           {:ok, manifest_bytes} <- File.read(manifest_path),
           {:ok, sig_bytes} <- File.read(sig_path),
           :ok <- sig_mod.verify_manifest(manifest_bytes, sig_bytes, pubkey),
           {:ok, manifest} <- Manifest.parse(manifest_bytes),
           :ok <- Manifest.check_expiry(manifest, enforce_expiry),
           :ok <- Manifest.check_counter(manifest, kv_get.(@counter_key)),
           {:ok, target_fn} <- fetch_target_fn(opts),
           target_name = target_fn.(),
           {:ok, target} <- Manifest.target(manifest, target_name),
           {:ok, fw_asset} <-
             find_release_asset(
               release.assets,
               target.asset,
               {:target_asset_missing, target.asset}
             ) do
        downloading_state = transition(state, :downloading, "Downloading firmware…", 0)

        fw_dl =
          client.download_asset(asset_url(fw_asset), fw_path,
            expected_sha256: target.sha256,
            expected_size: target.size,
            progress: &broadcast_progress(downloading_state, &1),
            req_options: Map.get(opts, :req_options) || []
          )

        with :ok <- fw_dl,
             {:ok, flashed_state} <- do_flash(downloading_state, opts, fw_path) do
          # The counter anchor only advances once the new firmware is
          # actually flashed — a failed flash must not move the
          # rollback floor. The flash already succeeded and reboot
          # must proceed either way, so a KV write failure here is
          # log-only, not install-failing.
          case kv_put.(@counter_key, Integer.to_string(manifest.counter)) do
            :ok ->
              :ok

            other ->
              Logger.error(
                "Failed to persist firmware rollback counter (#{inspect(other)}); " <>
                  "rollback protection may be stale until next successful install"
              )
          end

          {:ok, flashed_state}
        end
      end

    case result do
      {:ok, flashed_state} ->
        cleanup_partials([manifest_path, sig_path, fw_path])
        new_state = transition(flashed_state, :idle, "Install complete; rebooting.", 100)
        run_reboot(opts)
        {:noreply, new_state}

      {:error, reason} ->
        cleanup_partials([manifest_path, sig_path, fw_path])
        {:noreply, fail(state, "Install failed: #{format_error(reason)}", reason)}
    end
  end

  defp find_release_asset(assets, name, error_reason) do
    case Enum.find(assets, fn a -> a.name == name end) do
      nil -> {:error, error_reason}
      asset -> {:ok, asset}
    end
  end

  defp download_support_asset(client, asset, path, opts) do
    client.download_asset(asset_url(asset), path,
      # See asset_url/1 — no bearer on the public download URL.
      expected_size: Map.get(asset, :size, 0),
      progress: fn _ -> :ok end,
      req_options: Map.get(opts, :req_options) || []
    )
  end

  # Direct public download, no auth — v0.1 is public-repos-only. The
  # GitHub API asset `:url` route would work too, but needs an
  # `accept: application/octet-stream` + Bearer flow only needed for
  # private repos.
  defp asset_url(asset), do: Map.get(asset, :browser_download_url) || asset.url

  defp fetch_target_fn(opts) do
    case Map.get(opts, :target_fn) do
      fun when is_function(fun, 0) -> {:ok, fun}
      _ -> {:error, :missing_target_fn}
    end
  end

  defp client_mod(opts), do: Map.get(opts, :client, UniversalProxy.FirmwareUpdate.GithubClient)

  defp kv_get_fn(opts), do: Map.get(opts, :kv_get, fn _ -> nil end)
  defp kv_put_fn(opts), do: Map.get(opts, :kv_put, fn _, _ -> :ok end)
  defp current_version_fn(opts), do: Map.get(opts, :current_version_fn, fn -> nil end)

  defp run_reboot(opts) do
    case Map.get(opts, :reboot_fn) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  defp do_flash(state, opts, fw_path) do
    fwup = Map.get(opts, :fwup, UniversalProxy.FirmwareUpdate.Fwup)
    devpath = Map.get(opts, :fwup_devpath) || resolve_devpath(opts)
    task = Map.get(opts, :fwup_task, "upgrade")

    state = transition(state, :flashing, "Installing firmware…", 0)
    progress = &broadcast_progress(state, &1)

    case fwup.apply(fw_path, devpath: devpath, task: task, progress: progress) do
      :ok -> {:ok, state}
      {:error, _} = err -> err
    end
  end

  defp resolve_devpath(opts) do
    case Map.get(opts, :devpath_fn) do
      fun when is_function(fun, 0) -> fun.()
      _ -> nil
    end
  end

  defp transition(state, phase, message, pct \\ nil) do
    new = %{state | phase: phase, message: message, pct: pct}
    broadcast(new, %{phase: phase, message: message, pct: pct})
    new
  end

  defp broadcast_progress(state, {tag, pct}) do
    payload = %{phase: state.phase, message: state.message, pct: pct, progress_tag: tag}
    broadcast(state, payload)
  end

  defp broadcast(state, payload) do
    pubsub = Map.get(state.opts, :pubsub)
    topic = Map.get(state.opts, :pubsub_topic)

    if pubsub && topic && Code.ensure_loaded?(Phoenix.PubSub) do
      Phoenix.PubSub.broadcast(pubsub, topic, {:fw_update_progress, payload})
    end

    :ok
  end

  defp fail(state, message, reason) do
    new = %{state | phase: :error, message: message, last_error: reason, pct: nil}
    broadcast(new, %{phase: :error, message: message, pct: nil})
    new
  end

  defp public_state(state) do
    %{
      phase: state.phase,
      pct: state.pct,
      message: state.message,
      last_error: state.last_error,
      last_release: state.last_release,
      verification_required: Map.get(state.opts, :verification_required, false)
    }
  end

  defp validate_updates(updates) do
    Enum.reduce_while(updates, :ok, fn
      {k, _v}, _acc when k in @mutable_keys -> {:cont, :ok}
      {k, _v}, _acc when k in @immutable_keys -> {:halt, {:error, :immutable}}
      {_k, _v}, _acc -> {:halt, {:error, :unknown}}
    end)
  end

  defp scrub_partials(download_dir) do
    cleanup_partials([
      Path.join(download_dir, "firmware_pending.fw"),
      Path.join(download_dir, "firmware_pending.fw.sig"),
      Path.join(download_dir, "firmware_pending.fw.part"),
      Path.join(download_dir, "firmware_pending.fw.sig.part"),
      Path.join(download_dir, @manifest_asset),
      Path.join(download_dir, @manifest_asset <> ".part"),
      Path.join(download_dir, @manifest_sig_asset),
      Path.join(download_dir, @manifest_sig_asset <> ".part")
    ])
  end

  defp cleanup_partials(paths) do
    Enum.each(paths, &File.rm/1)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: reason |> inspect() |> safe_log()

  # Strip control characters (incl. ANSI escape sequences) before
  # interpolating attacker-controlled-ish strings into log/PubSub
  # messages. Release `tag_name` / `body` come from whoever cut the
  # GitHub release; harmless on the wire but could plant ANSI escapes
  # in `RingLogger` if a fork's release got malicious. Belt and braces.
  defp safe_log(nil), do: ""

  defp safe_log(s) when is_binary(s) do
    s
    |> String.replace(~r/[\x00-\x1f\x7f]/, " ")
    |> String.slice(0, 200)
  end

  defp safe_log(other), do: other |> inspect() |> safe_log()
end
