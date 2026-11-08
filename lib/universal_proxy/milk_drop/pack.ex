defmodule UniversalProxy.MilkDrop.Pack do
  # VintageNet is target-only: `apply/3` keeps the compiler and Dialyzer from
  # resolving it on host, where every call is gated by Code.ensure_loaded?/1.
  # credo:disable-for-this-file Credo.Check.Refactor.Apply
  @moduledoc """
  Downloads, verifies and extracts the pinned MilkDrop preset pack.

  The pin is compiled in, the way the firmware updater pins releases:

      config :universal_proxy, UniversalProxy.MilkDrop.Pack,
        version: "2026.11.1",                     # path-safe: [0-9A-Za-z._-]
        url: "https://github.com/.../up-milkdrop-pack-2026.11.1.tar.gz",
        sha256: "<64 hex chars>"

  With no pin (`version: nil`), `ensure/0` reports
  `{:error, :no_pack_pinned}`.

  ## Status

    * `:absent` — nothing extracted for the pinned version yet;
    * `{:downloading, pct}` — a download is running (0..100);
    * `{:ready, version, dir}` — the pack is extracted at `dir`;
    * `{:retrying, reason, next_in_ms}` — a transient failure (or no
      network yet, `:network_down`); the next attempt starts on its own in
      `next_in_ms` (see "Retries");
    * `{:error, reason}` — the last attempt failed for good; only
      `ensure/0` tries again.

  Every change (progress included, at most one per percent) is broadcast as
  `{:milkdrop_pack, status}` on `UniversalProxy.MilkDrop.pack_topic/0`.
  On start, an already-extracted `<root>/<version>/manifest.json` for the
  pin reads as `{:ready, ...}` without touching the network, and the
  starting status is broadcast as `{:milkdrop_pack_started, status}`: a
  Pack restarted after a crash (whose download died with it) is announced
  that way, so a subscriber caching `{:downloading, pct}` can drop it.

  ## Download

  `ensure/0` starts the download under the `:task_supervisor`
  (`UniversalProxy.MilkDrop.PackTasks` by default, which
  `UniversalProxy.MilkDrop.Supervisor` restarts together with this server)
  and monitors it (a crash becomes `{:error, {:crashed, reason}}`):

    1. `Req` streams into `<root>/<version>.tar.gz.part`; an existing
       `.part` is resumed with an HTTP `Range` request (a server that
       answers 200 instead restarts it from zero).
    2. The SHA-256 of the whole file is checked against the pin; a
       mismatch deletes the `.part` (`{:error, :checksum_mismatch}`).
    3. `:erl_tar` extracts it into `<root>/<version>.tmp`. Only regular
       files and directories with relative paths and no `..` segment are
       accepted (`{:error, {:unsafe_entry, name}}` otherwise), and the
       archive must have `manifest.json` at its root
       (`{:error, :missing_manifest}`).
    4. `<version>.tmp` is renamed to `<version>`; every other directory and
       `.part` file under the root is deleted, except the reserved `user`
       and `incoming` directories (user uploads, never touched by the
       installer; they are also refused as a pin version). Other files,
       such as `UniversalProxy.MilkDrop.Store`'s DETS file, are left alone.

  Filesystem failures are `{:error, {:io, posix}}`, HTTP failures
  `{:error, {:http_status, status}}` or `{:error, {:transport, reason}}`.

  ## Retries

  A transport error or an HTTP 5xx/429 answer is transient: the status
  becomes `{:retrying, reason, next_in_ms}` and the download starts again
  after `:retry_delays_ms` (5 s, 15 s, 60 s, then every 5 min), resuming
  the `.part`. Every other failure (a checksum mismatch, a bad pin, a disk
  error, a crash, …) is terminal. `ensure/0` during a backoff tries again
  at once and restarts the schedule.

  `ensure/0` first checks the network (VintageNet's `["connection"]` is
  `:lan` or `:internet`; always up where VintageNet is absent). Without it
  the status is `{:retrying, :network_down, next_in_ms}` and the download
  starts when the connection comes up or the backoff runs out, whichever
  is first; a connection coming up also cuts any other backoff short.

  The public API follows the `catch :exit` idiom: while the server is not
  running both functions return `{:error, :not_running}`.

  Tests override via `:name`, `:root`, `:pin` (`%{version:, url:,
  sha256:}`), `:req_options` (merged into the `Req` request, e.g.
  `plug: {Req.Test, name}`), `:task_supervisor`, `:pubsub`,
  `:retry_delays_ms` (the last one repeats), `:network_up?` (a 0-arity
  fun) and `:subscribe?` (subscribe to VintageNet, default `true`;
  `{VintageNet, ["connection"], old, new, meta}` messages drive it).
  """

  use GenServer

  require Logger

  alias UniversalProxy.MilkDrop

  @version_re ~r/\A[0-9A-Za-z][0-9A-Za-z._-]*\z/
  @sha256_re ~r/\A[0-9a-fA-F]{64}\z/
  # Hold user uploads: never a pack version, never swept by `cleanup/2`.
  @reserved ~w(user incoming)
  @read_chunk 65_536
  @task_supervisor UniversalProxy.MilkDrop.PackTasks
  @retry_delays_ms [5_000, 15_000, 60_000, 300_000]
  @connection_topic ["connection"]
  @up_states [:lan, :internet]

  @type pin :: %{version: String.t(), url: String.t(), sha256: String.t()}

  @type status ::
          :absent
          | {:downloading, 0..100}
          | {:ready, String.t(), String.t()}
          | {:retrying, term(), non_neg_integer()}
          | {:error, term()}

  # -- Client API --

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Make sure the pinned pack is (or becomes) available. Idempotent: starts
  a download unless one is running or the pack is ready. Returns the
  resulting status.
  """
  @spec ensure(GenServer.server()) :: status()
  def ensure(server \\ __MODULE__) do
    GenServer.call(server, :ensure)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "The current status (see the moduledoc)."
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "The default `:task_supervisor` the download runs under."
  @spec task_supervisor() :: atom()
  def task_supervisor, do: @task_supervisor

  @doc "The compiled-in pin, or `nil` when no pack is pinned."
  @spec configured_pin() :: map() | nil
  def configured_pin do
    config = Application.get_env(:universal_proxy, __MODULE__, [])

    case Keyword.get(config, :version) do
      nil -> nil
      version -> %{version: version, url: config[:url], sha256: config[:sha256]}
    end
  end

  # -- Server callbacks --

  @impl true
  def init(opts) do
    state = %{
      root: Keyword.get_lazy(opts, :root, &MilkDrop.root/0),
      pin: Keyword.get_lazy(opts, :pin, &configured_pin/0),
      req_options: Keyword.get(opts, :req_options, []),
      task_supervisor: Keyword.get(opts, :task_supervisor, @task_supervisor),
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      retry_delays_ms: Keyword.get(opts, :retry_delays_ms, @retry_delays_ms),
      network_up?: Keyword.get(opts, :network_up?, &network_up?/0),
      subscribe?: Keyword.get(opts, :subscribe?, true),
      status: :absent,
      task: nil,
      attempts: 0,
      retry: nil
    }

    {:ok, %{state | status: initial_status(state)}, {:continue, :announce}}
  end

  @impl true
  def handle_continue(:announce, state) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      MilkDrop.pack_topic(),
      {:milkdrop_pack_started, state.status}
    )

    if state.subscribe?, do: subscribe_connection()
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:ensure, _from, %{status: status} = state)
      when elem(status, 0) in [:downloading, :ready] do
    {:reply, status, state}
  end

  def handle_call(:ensure, _from, state) do
    state = state |> cancel_retry() |> Map.put(:attempts, 0)

    case validate_pin(state.pin) do
      {:ok, pin} ->
        state =
          if state.network_up?.(),
            do: start_download(state, pin),
            else: schedule_retry(state, :network_down)

        {:reply, state.status, state}

      {:error, _} = error ->
        {:reply, error, set_status(state, error)}
    end
  end

  @impl true
  def handle_info({:pack_progress, ref, pct}, %{task: {_pid, _mref, ref}} = state) do
    {:noreply, set_status(state, {:downloading, pct})}
  end

  def handle_info({:pack_result, ref, result}, %{task: {_pid, mref, ref}} = state) do
    Process.demonitor(mref, [:flush])

    state = %{state | task: nil}

    case result do
      {:ok, version, dir} ->
        Logger.info("MilkDrop pack #{version} ready at #{dir}")
        {:noreply, set_status(%{state | attempts: 0}, {:ready, version, dir})}

      {:error, reason} = error ->
        if transient?(reason) do
          state = schedule_retry(state, reason)
          {:retrying, _reason, ms} = state.status

          Logger.warning(
            "MilkDrop pack download failed: #{inspect(reason)}; retrying in #{div(ms, 1000)} s"
          )

          {:noreply, state}
        else
          Logger.warning("MilkDrop pack download failed: #{inspect(reason)}")
          {:noreply, set_status(%{state | attempts: 0}, error)}
        end
    end
  end

  def handle_info({:DOWN, mref, :process, _pid, reason}, %{task: {_pid2, mref, _ref}} = state) do
    Logger.error("MilkDrop pack download crashed: #{inspect(reason)}")
    state = %{state | task: nil, attempts: 0}
    {:noreply, set_status(state, {:error, {:crashed, crash_reason(reason)}})}
  end

  def handle_info({:pack_retry, token}, %{retry: {_timer, token}} = state),
    do: {:noreply, retry_now(%{state | retry: nil})}

  # The connection came up (or got better): a pending retry starts at once.
  def handle_info({VintageNet, @connection_topic, old, new, _meta}, %{retry: {_, _}} = state) do
    if new in @up_states and new != old,
      do: {:noreply, retry_now(cancel_retry(state))},
      else: {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private: server --

  defp initial_status(%{pin: pin, root: root}) do
    with {:ok, pin} <- validate_pin(pin),
         dir = Path.join(root, pin.version),
         true <- File.regular?(Path.join(dir, "manifest.json")) do
      {:ready, pin.version, dir}
    else
      _ -> :absent
    end
  end

  defp transient?({:transport, _reason}), do: true
  defp transient?({:http_status, status}), do: status == 429 or status in 500..599
  defp transient?(_reason), do: false

  defp schedule_retry(state, reason) do
    delay = Enum.at(state.retry_delays_ms, state.attempts, List.last(state.retry_delays_ms))
    token = make_ref()
    timer = Process.send_after(self(), {:pack_retry, token}, delay)

    %{state | attempts: state.attempts + 1, retry: {timer, token}}
    |> set_status({:retrying, reason, delay})
  end

  defp cancel_retry(%{retry: {timer, _token}} = state) do
    Process.cancel_timer(timer)
    %{state | retry: nil}
  end

  defp cancel_retry(state), do: state

  # A pin that validated once still does: this only re-reads it.
  defp retry_now(state) do
    case validate_pin(state.pin) do
      {:ok, pin} -> start_download(state, pin)
      {:error, _} = error -> set_status(state, error)
    end
  end

  defp validate_pin(nil), do: {:error, :no_pack_pinned}

  defp validate_pin(%{version: version, url: url, sha256: sha256} = pin)
       when is_binary(version) and is_binary(url) and is_binary(sha256) do
    if version =~ @version_re and version not in @reserved and sha256 =~ @sha256_re do
      {:ok, %{pin | sha256: String.downcase(sha256)}}
    else
      {:error, :invalid_pin}
    end
  end

  defp validate_pin(_pin), do: {:error, :invalid_pin}

  defp start_download(state, pin) do
    server = self()
    ref = make_ref()
    root = state.root
    req_options = state.req_options

    fun = fn ->
      progress = fn pct -> send(server, {:pack_progress, ref, pct}) end
      send(server, {:pack_result, ref, install(pin, root, req_options, progress)})
    end

    case Task.Supervisor.start_child(state.task_supervisor, fun) do
      {:ok, pid} ->
        mref = Process.monitor(pid)
        set_status(%{state | task: {pid, mref, ref}}, {:downloading, 0})

      {:error, reason} ->
        set_status(state, {:error, {:crashed, reason}})
    end
  catch
    :exit, reason -> set_status(state, {:error, {:crashed, reason}})
  end

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    Phoenix.PubSub.broadcast(state.pubsub, MilkDrop.pack_topic(), {:milkdrop_pack, status})
    %{state | status: status}
  end

  defp crash_reason({%{__exception__: true} = exception, _stack}), do: exception
  defp crash_reason(reason), do: reason

  # -- Private: download task --

  defp install(pin, root, req_options, progress) do
    part = Path.join(root, pin.version <> ".tar.gz.part")
    tmp = Path.join(root, pin.version <> ".tmp")
    dir = Path.join(root, pin.version)

    with :ok <- io(File.mkdir_p(root)),
         :ok <- download(pin.url, part, req_options, progress),
         :ok <- verify(part, pin.sha256),
         :ok <- extract(part, tmp),
         :ok <- io(rm_rf(dir)),
         :ok <- io(File.rename(tmp, dir)) do
      cleanup(root, pin.version)
      {:ok, pin.version, dir}
    else
      {:error, reason} = error ->
        if reason in [:checksum_mismatch, :bad_range], do: File.rm(part)
        _ = rm_rf(tmp)
        error
    end
  end

  defp download(url, part, req_options, progress) do
    offset =
      case File.stat(part) do
        {:ok, %File.Stat{type: :regular, size: size}} -> size
        _ -> 0
      end

    with {:ok, fd} <- io(:file.open(part, [:append, :binary, :raw])) do
      try do
        request(url, offset, fd, req_options, progress)
      after
        :file.close(fd)
      end
    end
  end

  defp request(url, offset, fd, req_options, progress) do
    headers = if offset > 0, do: [{"range", "bytes=#{offset}-"}], else: []

    req =
      [url: url, headers: headers, raw: true, retry: false]
      |> Req.new()
      |> Req.merge(req_options)
      |> Req.merge(into: &stream_chunk(&1, &2, fd, offset, progress))

    case Req.get(req) do
      {:ok, resp} -> response_result(resp)
      {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport, reason}}
      {:error, exception} -> {:error, {:download, Exception.message(exception)}}
    end
  end

  # Runs for every body chunk of every response, redirects included: only a
  # 200/206 body is written. Per-response bookkeeping lives in its private
  # map, so a redirect's final response starts afresh.
  defp stream_chunk({:data, data}, {req, resp}, fd, offset, progress) do
    case begin_body(resp, fd, offset) do
      {:ok, resp} ->
        case :file.write(fd, data) do
          :ok ->
            {:cont, {req, track_progress(resp, byte_size(data), progress)}}

          {:error, reason} ->
            {:halt, {req, Req.Response.put_private(resp, :pack_error, {:io, reason})}}
        end

      :skip ->
        {:cont, {req, resp}}

      {:error, reason} ->
        {:halt, {req, Req.Response.put_private(resp, :pack_error, reason)}}
    end
  end

  defp begin_body(resp, fd, offset) do
    cond do
      Req.Response.get_private(resp, :pack_written) != nil ->
        {:ok, resp}

      resp.status == 206 ->
        case content_range(resp) do
          {^offset, total} -> {:ok, start_body(resp, offset, total)}
          _ -> {:error, :bad_range}
        end

      resp.status == 200 ->
        with :ok <- truncate(fd, offset) do
          {:ok, start_body(resp, 0, content_length(resp))}
        end

      true ->
        :skip
    end
  end

  defp truncate(_fd, 0), do: :ok

  defp truncate(fd, _offset) do
    with {:ok, 0} <- io(:file.position(fd, 0)), do: io(:file.truncate(fd))
  end

  defp start_body(resp, start, total) do
    resp
    |> Req.Response.put_private(:pack_written, start)
    |> Req.Response.put_private(:pack_total, total)
    |> Req.Response.put_private(:pack_pct, nil)
  end

  defp track_progress(resp, bytes, progress) do
    written = Req.Response.get_private(resp, :pack_written) + bytes
    resp = Req.Response.put_private(resp, :pack_written, written)

    with total when is_integer(total) and total > 0 <-
           Req.Response.get_private(resp, :pack_total),
         pct = min(div(written * 100, total), 100),
         true <- pct != Req.Response.get_private(resp, :pack_pct) do
      progress.(pct)
      Req.Response.put_private(resp, :pack_pct, pct)
    else
      _ -> resp
    end
  end

  defp response_result(resp) do
    case {Req.Response.get_private(resp, :pack_error), resp.status} do
      {nil, status} when status in [200, 206] -> :ok
      # Nothing left to send: the .part is already whole (verify decides).
      {nil, 416} -> :ok
      {nil, status} -> {:error, {:http_status, status}}
      {reason, _status} -> {:error, reason}
    end
  end

  defp content_range(resp) do
    with [value | _] <- Req.Response.get_header(resp, "content-range"),
         [_, start, total] <- Regex.run(~r/\Abytes (\d+)-\d+\/(\d+|\*)\z/, value) do
      {String.to_integer(start), if(total == "*", do: nil, else: String.to_integer(total))}
    else
      _ -> nil
    end
  end

  defp content_length(resp) do
    with [value | _] <- Req.Response.get_header(resp, "content-length"),
         {length, ""} <- Integer.parse(value) do
      length
    else
      _ -> nil
    end
  end

  defp verify(part, expected) do
    case sha256_file(part) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, :checksum_mismatch}
      {:error, _} = error -> error
    end
  end

  defp sha256_file(path) do
    with {:ok, fd} <- io(:file.open(path, [:read, :binary, :raw])) do
      try do
        hash_file(fd, :crypto.hash_init(:sha256))
      after
        :file.close(fd)
      end
    end
  end

  defp hash_file(fd, ctx) do
    case :file.read(fd, @read_chunk) do
      {:ok, data} -> hash_file(fd, :crypto.hash_update(ctx, data))
      :eof -> {:ok, ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)}
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp extract(archive, tmp) do
    archive = to_charlist(archive)

    with :ok <- io(rm_rf(tmp)),
         :ok <- io(File.mkdir_p(tmp)),
         {:ok, entries} <- tar(:erl_tar.table(archive, [:compressed, :verbose])),
         :ok <- check_entries(entries),
         :ok <- tar(:erl_tar.extract(archive, [:compressed, {:cwd, to_charlist(tmp)}])) do
      if File.regular?(Path.join(tmp, "manifest.json")),
        do: :ok,
        else: {:error, :missing_manifest}
    end
  end

  defp check_entries(entries) do
    Enum.find_value(entries, :ok, fn {name, type, _size, _mtime, _mode, _uid, _gid} ->
      name = List.to_string(name)
      if safe_entry?(name, type), do: nil, else: {:error, {:unsafe_entry, name}}
    end)
  end

  defp safe_entry?(name, type) do
    type in [:regular, :directory] and Path.type(name) == :relative and
      ".." not in Path.split(name)
  end

  defp tar({:error, {_name, reason}}) when is_atom(reason), do: {:error, {:io, reason}}
  defp tar({:error, reason}), do: {:error, {:extract, reason}}
  defp tar(other), do: other

  # Delete every other version dir, stale `.tmp` dir and `.part` file
  # (never the `@reserved` upload dirs).
  defp cleanup(root, version) do
    case File.ls(root) do
      {:ok, names} ->
        for name <- names, name != version, stale?(root, name) do
          _ = rm_rf(Path.join(root, name))
        end

      {:error, _} ->
        []
    end
  end

  defp stale?(_root, name) when name in @reserved, do: false

  defp stale?(root, name) do
    String.ends_with?(name, ".part") or File.dir?(Path.join(root, name))
  end

  defp rm_rf(path) do
    case File.rm_rf(path) do
      {:ok, _} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp io({:error, reason}) when is_atom(reason), do: {:error, {:io, reason}}
  defp io(other), do: other

  # -- Private: network --

  defp network_up? do
    if Code.ensure_loaded?(VintageNet),
      do: apply(VintageNet, :get, [@connection_topic]) in @up_states,
      else: true
  rescue
    # VintageNet not started yet: no network either.
    ArgumentError -> false
  end

  defp subscribe_connection do
    if Code.ensure_loaded?(VintageNet) do
      _ = Application.ensure_all_started(:vintage_net)
      apply(VintageNet, :subscribe, [@connection_topic])
    end
  rescue
    ArgumentError -> :ok
  end
end
