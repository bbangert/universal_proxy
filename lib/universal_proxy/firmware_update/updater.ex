defmodule UniversalProxy.FirmwareUpdate.Updater do
  @moduledoc """
  Firmware update orchestration GenServer.

  Library-shape: no host dependencies. All wiring (PubSub module,
  topic, download dir, fwup devpath/task, GithubClient module,
  asset-matcher closure) comes through `start_link/1` opts.

  ## State machine

      :idle ─→ :checking ─→ :downloading ─→ :verifying ─→ :flashing ─→ :idle
                                          ↘ (verification disabled) ↗
                                          ↘     :error                 ↗

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
  the install completes. A LiveView that reconnects mid-install
  therefore sees a stale `pct` for the brief window until the next
  PubSub event lands and corrects it.

  ## Conditional verification

  When opts `:verification_required` is `false` (v1 default), the
  flow skips `:verifying` entirely and goes `:downloading → :flashing`.
  A `Logger.warning` fires on every such install so the unverified
  state is auditable in `RingLogger`.

  ## Test seams

    * `:client` — module implementing `latest_release/2` and
      `download_asset/3` (default `UniversalProxy.FirmwareUpdate.GithubClient`).
    * `:fwup` — module implementing `apply/2` (default
      `UniversalProxy.FirmwareUpdate.Fwup`).
    * `:signature` — module implementing `verify/3` (default
      `UniversalProxy.FirmwareUpdate.Signature`).
  """

  use GenServer

  require Logger

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
    :devpath_fn
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

  @doc "Synchronous snapshot used by LiveView mount."
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
        # opts contract.
        new_state =
          transition(
            %{state | last_error: nil},
            :downloading,
            "Downloading firmware…",
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
    client = Map.get(opts, :client, UniversalProxy.FirmwareUpdate.GithubClient)
    repo = Map.fetch!(opts, :owner_repo)

    client_opts =
      [github_token: Map.get(opts, :github_token), etag: state.etag]
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
    matcher = Map.fetch!(opts, :asset_matcher)

    case matcher.(release.tag_name, release.assets) do
      {:ok, fw_asset, sig_asset} ->
        do_download_install(state, opts, fw_asset, sig_asset)

      {:error, reason} ->
        {:noreply, fail(state, "No matching firmware asset: #{format_error(reason)}", reason)}
    end
  end

  # -- Private --

  defp do_download_install(state, opts, fw_asset, sig_asset) do
    client = Map.get(opts, :client, UniversalProxy.FirmwareUpdate.GithubClient)
    download_dir = Map.fetch!(opts, :download_dir)
    verify_required = Map.get(opts, :verification_required, false)

    fw_path = Path.join(download_dir, "firmware_pending.fw")
    sig_path = Path.join(download_dir, "firmware_pending.fw.sig")

    # Phase was set to :downloading synchronously in handle_call(:install_latest, ...)
    # so the busy-check rejects concurrent installs. No need to re-transition here.

    fw_dl =
      client.download_asset(fw_asset.url, fw_path,
        # Intentionally no github_token here: asset URLs from
        # `browser_download_url` are public S3 redirects that don't
        # need (and shouldn't see) the operator bearer.
        expected_size: Map.get(fw_asset, :size, 0),
        progress: &broadcast_progress(state, &1),
        req_options: Map.get(opts, :req_options)
      )

    with :ok <- fw_dl,
         :ok <- maybe_download_sig(client, sig_asset, sig_path, opts, verify_required),
         {:ok, state} <- maybe_verify(state, fw_path, sig_path, opts, verify_required),
         {:ok, state} <- do_flash(state, opts, fw_path) do
      cleanup_partials([fw_path, sig_path])
      new_state = transition(state, :idle, "Install complete; rebooting.", 100)
      run_reboot(opts)
      {:noreply, new_state}
    else
      {:error, reason} ->
        cleanup_partials([fw_path, sig_path])
        {:noreply, fail(state, "Install failed: #{format_error(reason)}", reason)}
    end
  end

  defp run_reboot(opts) do
    case Map.get(opts, :reboot_fn) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  defp maybe_download_sig(_client, _asset, _path, _opts, false), do: :ok

  defp maybe_download_sig(_client, nil, _path, _opts, true),
    do: {:error, :missing_signature_asset}

  defp maybe_download_sig(client, sig_asset, sig_path, opts, true) do
    client.download_asset(sig_asset.url, sig_path,
      # See do_download_install/3 — no bearer on browser_download_url.
      expected_size: Map.get(sig_asset, :size, 64),
      progress: fn _ -> :ok end,
      req_options: Map.get(opts, :req_options)
    )
  end

  defp maybe_verify(state, _fw_path, _sig_path, _opts, false) do
    Logger.warning(
      "Firmware install proceeding without signature verification (verification_required=false)"
    )

    {:ok, state}
  end

  defp maybe_verify(state, fw_path, sig_path, opts, true) do
    sig_mod = Map.get(opts, :signature, UniversalProxy.FirmwareUpdate.Signature)
    pubkey = Map.get(opts, :public_key)

    new_state = transition(state, :verifying, "Verifying signature…")

    case sig_mod.verify(fw_path, sig_path, pubkey) do
      :ok -> {:ok, new_state}
      {:error, _} = err -> err
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
      Path.join(download_dir, "firmware_pending.fw.sig.part")
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
