defmodule UniversalProxy.Display.MilkDrop do
  @moduledoc """
  Port owner for the `milkdrop_renderer` binary while the MilkDrop display
  mode is active.

  Started by its owner (the display's State) with `start_link/1` or
  `start/1`. It is not supervised: the owner monitors it and gets every
  renderer event as `{:milkdrop, pid, event}` and the binary's exit as
  `{:milkdrop_exit, pid, status}`, after which this process stops. If the
  owner dies (linked or not), this process stops and its port closes (the
  renderer sees EOF on stdin).

  All commands are casts and are written without blocking: a renderer that
  stops reading stdin (its pipe and the port queue full) is reported as
  `{:milkdrop_exit, pid, :wedged}` and this process stops with
  `{:shutdown, :wedged}`.

  A renderer that ignores EOF or has stopped reading would otherwise keep
  DRM master, so a reaper task (under `:task_supervisor`) owns its cleanup.
  The reaper is started before the renderer is spawned — no reaper, no
  renderer — and:

    * however this process ends (stopped, its owner gone, crashed or
      killed), SIGKILLs a renderer still running `:kill_grace_ms` later;
    * when shut down by its supervisor (application teardown, a restart of
      the task supervisor), SIGKILLs a still-running renderer and waits up
      to 1 s for it to be gone before it exits, within its shutdown budget.
      A supervisor that restarts its children only once they are down (the
      display subtree) thus restarts them with the renderer gone.

  Once the renderer process is confirmed gone (its exit status arrived, or
  `/proc/<os_pid>` is gone or a zombie, after the grace period and SIGKILL
  if needed), the owner gets `{:milkdrop_reaped, pid}`; until then it may
  still hold DRM master. Not sent when the renderer could not be confirmed
  gone within 1 s of its SIGKILL, nor on a supervisor shutdown.

  If the reaper dies while the renderer runs, this process SIGKILLs the
  renderer, reports `{:milkdrop_exit, pid, :reaper_down}` (then
  `{:milkdrop_reaped, pid}` once it is gone, waiting up to 1 s) and stops
  with `{:shutdown, :reaper_down}`.

  ## Options

    * `:owner` — pid to report to (default: the caller);
    * `:mode` — `%{width:, height:}`, the output size to present at, with
      an optional `:refresh` (Hz) to pin as well (required; see `--mode`);
    * `:card` — the DRM card node to present on (`"/dev/dri/card1"`;
      default: the renderer's, `/dev/dri/card0`);
    * `:connector` — the DRM connector to present on (`"HDMI-A-1"`;
      default: the renderer's first connected HDMI connector);
    * `:pack_dir`, `:pack_version` — the extracted pack and its version
      (required; the version keys persisted skips);
    * `:ladder` — internal resolutions, highest first (default
      `default_ladder/1` for this target);
    * `:ring_path` — the Sendspin player's PCM tap ring (optional: without
      it the renderer draws silence);
    * `:settings`, `:skipped` — default to `UniversalProxy.MilkDrop.Store`'s
      settings and skip list for `:pack_version`; `:store` names the Store;
    * `:skip_file` — where the skip list is written for the renderer
      (default a unique `<tmp>/up-milkdrop-skip-N.txt`; deleted by the
      reaper however this process ends);
    * `:binary` — the renderer (default `default_binary/0`);
    * `:skip_retry_ms` — how often skips the Store could not take are
      retried (default 5000);
    * `:kill_grace_ms` — how long a renderer that outlives its closed stdin
      may run before it is SIGKILLed (default 2000);
    * `:task_supervisor` — the `Task.Supervisor` the reaper runs under
      (default `UniversalProxy.TaskSupervisor`).

  ## Renderer CLI contract

      milkdrop_renderer --mode 1280x720[@60] --pack-dir DIR
                        --ladder 640x360,480x270 --rotate-s 20
                        --skip-file PATH
                        [--high-frequency] [--locked FILE] [--pcm-ring PATH]
                        [--card /dev/dri/card1] [--connector HDMI-A-1]

    * `--mode` — the CRTC mode to present on. `WxH` keeps the mode the CRTC
      scans out when the renderer opens the card if it is that size,
      whatever its refresh (no modeset), else the connector's preferred
      (or highest-refresh) mode at that size; `WxH@Hz` also pins the
      refresh (within 0.5 Hz);
    * `--card` — the DRM card node to open (default `/dev/dri/card0`);
    * `--connector` — the connector to present on; it must be connected;
    * `--pack-dir` — the extracted pack; `manifest.json` at its root;
    * `--ladder` — comma-separated internal-resolution rungs, highest
      first; the renderer steps down per preset and skips past the last;
    * `--rotate-s` — auto-rotation interval in seconds (10..120);
    * `--skip-file` — UTF-8 text, one pack-relative preset file per line
      (`\\n`-separated, possibly empty): presets never to load;
    * `--high-frequency` — include `high_frequency/` presets;
    * `--locked` — start locked on this pack-relative preset file;
    * `--pcm-ring` — the PCM tap ring file.

  ## Line-JSON protocol

  One JSON object per line in each direction; lines stay under 4096 bytes.
  Commands (stdin):

    * `{"cmd":"take"}` — become DRM master, commit `--mode` and present;
    * `{"cmd":"release"}` — stop flipping, close the framebuffer (keeping
      the scanout), drop master; the card stays open;
    * `{"cmd":"exit"}` — close the card, report `exiting`, exit 0;
    * `{"cmd":"next"}`, `{"cmd":"prev"}` — change preset (with history);
    * `{"cmd":"lock"}`, `{"cmd":"unlock"}` — hold / resume rotation on the
      current preset;
    * `{"cmd":"set_rotate","value":N}` — rotation interval in seconds;
    * `{"cmd":"set_high_frequency","value":B}` — include `high_frequency/`.

  Events (stdout), forwarded with atom keys and an atom `:event`:

    * `{"event":"prepared","mode":M,"connector":C,"mode_source":S,...}` —
      GL is up and the first preset warmed, not yet master; `mode` is the
      chosen `WxH@Hz`, `mode_source` how it was chosen (`crtc`: no
      modeset);
    * `{"event":"presenting"}` — `take` done, frames are on screen;
    * `{"event":"released"}` — `release` done, master dropped;
    * `{"event":"preset","file":F,"locked":B,...}` — preset `F` is showing;
    * `{"event":"skip","preset":F,"reason":R}` — `F` cannot be drawn
      (persisted to the Store for this pack version). The forwarded event
      carries `persisted: true | false`; while the Store cannot take it
      (not running) it is kept and retried on the next `skip` or `preset`
      event and every `:skip_retry_ms`, until the process ends;
    * `{"event":"stats",...}` — periodic counters (fps, rung, temperature,
      ARM clock);
    * `{"event":"error","reason":R,...}` — a non-fatal problem;
    * `{"event":"exiting","reason":R}` — about to exit (`"requested"`,
      `"thermal"`, …).

  Other lines (unknown events, non-JSON, over-long lines) are dropped and
  logged at debug level.

  The renderer must exit when stdin reaches EOF, and must keep anything
  but protocol lines (Mesa's shader dumps in particular) off stdout.

  A `preset` event whose `locked` differs from the stored setting persists
  it to the Store (`locked: file` or `nil`), so a lock survives a restart.
  """

  use GenServer

  require Logger

  alias UniversalProxy.MilkDrop.Store

  @line_max 4096
  @kill_grace_ms 2_000
  @skip_retry_ms 5_000
  # Time the reaper's supervisor allows it to SIGKILL the renderer on shutdown.
  @reaper_shutdown_ms 5_000
  @target Mix.target()

  @events %{
    "prepared" => :prepared,
    "presenting" => :presenting,
    "released" => :released,
    "preset" => :preset,
    "skip" => :skip,
    "stats" => :stats,
    "error" => :error,
    "exiting" => :exiting
  }

  @resolution_re ~r/\A[1-9]\d{0,4}x[1-9]\d{0,4}\z/
  @connector_re ~r/\A[A-Za-z0-9-]{1,32}\z/
  # How long a SIGKILLed renderer may take to disappear before giving up
  # on confirming it, and how often /proc is looked at meanwhile.
  @kill_confirm_ms 1_000
  @reap_poll_ms 20

  @type mode :: %{
          required(:width) => pos_integer(),
          required(:height) => pos_integer(),
          optional(:refresh) => number() | nil
        }

  # -- Client API --

  @doc "Start linked to the caller (the default owner)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, Keyword.put_new(opts, :owner, self()))

  @doc "Start unlinked; the owner (default: the caller) is still monitored."
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: GenServer.start(__MODULE__, Keyword.put_new(opts, :owner, self()))

  @doc "Close the port and stop. `:ok` if it is already gone."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server)
  catch
    :exit, _ -> :ok
  end

  @doc "Take DRM master and present."
  @spec take(GenServer.server()) :: :ok
  def take(server), do: command(server, %{cmd: "take"})

  @doc "Stop presenting and drop DRM master, keeping the card open."
  @spec release(GenServer.server()) :: :ok
  def release(server), do: command(server, %{cmd: "release"})

  @doc "Ask the renderer to close the card and exit."
  @spec exit(GenServer.server()) :: :ok
  def exit(server), do: command(server, %{cmd: "exit"})

  @doc "Next preset."
  @spec next(GenServer.server()) :: :ok
  def next(server), do: command(server, %{cmd: "next"})

  @doc "Previous preset."
  @spec prev(GenServer.server()) :: :ok
  def prev(server), do: command(server, %{cmd: "prev"})

  @doc "Hold rotation on the current preset."
  @spec lock(GenServer.server()) :: :ok
  def lock(server), do: command(server, %{cmd: "lock"})

  @doc "Resume rotation."
  @spec unlock(GenServer.server()) :: :ok
  def unlock(server), do: command(server, %{cmd: "unlock"})

  @doc "Set the rotation interval in seconds."
  @spec set_rotate(GenServer.server(), pos_integer()) :: :ok
  def set_rotate(server, seconds) when is_integer(seconds) and seconds > 0,
    do: command(server, %{cmd: "set_rotate", value: seconds})

  @doc "Include or exclude `high_frequency/` presets."
  @spec set_high_frequency(GenServer.server(), boolean()) :: :ok
  def set_high_frequency(server, enabled?) when is_boolean(enabled?),
    do: command(server, %{cmd: "set_high_frequency", value: enabled?})

  @doc false
  @spec command(GenServer.server(), map()) :: :ok
  def command(server, cmd) when is_map(cmd), do: GenServer.cast(server, {:command, cmd})

  @doc """
  The internal-resolution ladder for a target, highest rung first (rpi3
  and anything else get the lowest one).
  """
  @spec default_ladder(atom()) :: [String.t()]
  def default_ladder(target \\ @target)
  def default_ladder(:rpi4), do: ~w(960x540 640x360 480x270)
  def default_ladder(:rpi5), do: ~w(1280x720 960x540 640x360)
  def default_ladder(_target), do: ~w(640x360 480x270)

  @doc "Where this target's renderer binary is installed."
  @spec default_binary() :: String.t()
  def default_binary do
    Path.join([
      :code.priv_dir(:universal_proxy) |> List.to_string(),
      "milkdrop_renderer",
      to_string(@target),
      "milkdrop_renderer"
    ])
  end

  @doc """
  The renderer's argv (see "Renderer CLI contract") for `config`: `:mode`,
  `:pack_dir`, `:ladder`, `:skip_file`, `:settings` and the optional
  `:ring_path`, `:card` and `:connector`.
  """
  @spec args(map()) :: [String.t()]
  def args(%{mode: mode, pack_dir: pack_dir, ladder: ladder, skip_file: skip_file} = config) do
    settings = Map.merge(Store.defaults(), config[:settings] || %{})

    [
      ["--mode", format_mode(mode)],
      ["--pack-dir", pack_dir],
      ["--ladder", Enum.join(ladder, ",")],
      ["--rotate-s", Integer.to_string(settings.rotate_s)],
      ["--skip-file", skip_file],
      if(settings.include_high_frequency, do: ["--high-frequency"], else: []),
      if(settings.locked, do: ["--locked", settings.locked], else: []),
      if(config[:ring_path], do: ["--pcm-ring", config.ring_path], else: []),
      if(config[:card], do: ["--card", config.card], else: []),
      if(config[:connector], do: ["--connector", config.connector], else: [])
    ]
    |> Enum.concat()
  end

  # -- Server callbacks --

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    version = Keyword.fetch!(opts, :pack_version)
    store = Keyword.get(opts, :store, Store)
    settings = Keyword.get_lazy(opts, :settings, fn -> Store.settings(store) end)
    skipped = Keyword.get_lazy(opts, :skipped, fn -> Store.skipped(store, version) end)

    config = %{
      mode: Keyword.fetch!(opts, :mode),
      pack_dir: Keyword.fetch!(opts, :pack_dir),
      ladder: Keyword.get_lazy(opts, :ladder, &default_ladder/0),
      ring_path: Keyword.get(opts, :ring_path),
      card: Keyword.get(opts, :card),
      connector: Keyword.get(opts, :connector),
      settings: settings,
      skip_file:
        Keyword.get_lazy(opts, :skip_file, fn ->
          Path.join(
            System.tmp_dir!(),
            "up-milkdrop-skip-#{System.unique_integer([:positive])}.txt"
          )
        end)
    }

    binary = Keyword.get_lazy(opts, :binary, &default_binary/0)

    kill_grace_ms = Keyword.get(opts, :kill_grace_ms, @kill_grace_ms)
    task_sup = Keyword.get(opts, :task_supervisor, UniversalProxy.TaskSupervisor)

    with :ok <- validate(config),
         :ok <- write_skip_file(config.skip_file, skipped),
         {:ok, reaper} <- start_reaper(task_sup, owner, kill_grace_ms, config.skip_file),
         {:ok, port} <- open_port(binary, args(config)) do
      os_pid = os_pid(port)
      send(reaper, if(os_pid, do: {:os_pid, os_pid}, else: :renderer_exited))

      {:ok,
       %{
         owner: owner,
         owner_ref: Process.monitor(owner),
         port: port,
         os_pid: os_pid,
         reaper: reaper,
         reaper_ref: Process.monitor(reaper),
         store: store,
         version: version,
         locked: Map.get(settings, :locked),
         skip_file: config.skip_file,
         discarding: false,
         pending_skips: %{},
         skip_retry_ms: Keyword.get(opts, :skip_retry_ms, @skip_retry_ms),
         skip_timer: nil
       }}
    else
      {:error, reason} ->
        Logger.error("MilkDrop renderer did not start: #{inspect(reason)}")
        _ = File.rm(config.skip_file)
        {:stop, reason}
    end
  end

  @impl true
  # `:nosuspend`: a busy port would otherwise suspend this process, leaving
  # owner death and `stop/1` unhandled.
  def handle_cast({:command, cmd}, %{port: port} = state) when is_port(port) do
    if Port.command(port, [Jason.encode!(cmd), "\n"], [:nosuspend]) do
      {:noreply, state}
    else
      Logger.warning("MilkDrop renderer is not reading its commands; stopping it")
      send(state.owner, {:milkdrop_exit, self(), :wedged})
      {:stop, {:shutdown, :wedged}, state}
    end
  rescue
    ArgumentError -> {:noreply, state}
  end

  def handle_cast({:command, _cmd}, state), do: {:noreply, state}

  @impl true
  # A line longer than the port's line buffer arrives as `:noeol` fragments
  # ending in one `:eol` tail; the whole line is dropped.
  def handle_info({port, {:data, {:noeol, _chunk}}}, %{port: port} = state) do
    unless state.discarding, do: Logger.debug("MilkDrop renderer: dropped an over-long line")
    {:noreply, %{state | discarding: true}}
  end

  def handle_info({port, {:data, {:eol, _tail}}}, %{port: port, discarding: true} = state) do
    {:noreply, %{state | discarding: false}}
  end

  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    {:noreply, handle_line(line, state)}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    level = if status == 0, do: :info, else: :warning
    Logger.log(level, "MilkDrop renderer exited with status #{status}")
    send(state.reaper, :renderer_exited)
    send(state.owner, {:milkdrop_exit, self(), status})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  # Nothing would clean up after this process any more, so the renderer is
  # killed and awaited (briefly) here, and the owner told it was reaped.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{reaper_ref: ref} = state) do
    Logger.warning("MilkDrop reaper went down (#{inspect(reason)}); killing the renderer")
    if state.os_pid, do: kill(state.os_pid)
    send(state.owner, {:milkdrop_exit, self(), :reaper_down})

    if is_nil(state.os_pid) or await_gone(state.os_pid, @kill_confirm_ms) == :gone,
      do: send(state.owner, {:milkdrop_reaped, self()})

    {:stop, {:shutdown, :reaper_down}, state}
  end

  def handle_info(:retry_skips, state) do
    {:noreply, state |> Map.put(:skip_timer, nil) |> flush_skips()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Private --

  defp handle_line(line, state) do
    case decode_event(line) do
      {:ok, event} ->
        {event, state} = persist(event, state)
        send(state.owner, {:milkdrop, self(), event})
        state

      :ignore ->
        Logger.debug("MilkDrop renderer: ignored line #{inspect(line)}")
        state
    end
  end

  # Keys are atomised only for known events: the binary's emit sites are
  # the only producers of those, so their key set is finite.
  defp decode_event(line) do
    with {:ok, %{"event" => name}} when is_map_key(@events, name) <- Jason.decode(line),
         {:ok, event} <- Jason.decode(line, keys: :atoms) do
      {:ok, %{event | event: Map.fetch!(@events, name)}}
    else
      _ -> :ignore
    end
  end

  defp persist(%{event: :skip, preset: preset} = event, state) when is_binary(preset) do
    reason = if is_binary(event[:reason]), do: event.reason, else: "unknown"
    state = flush_skips(%{state | pending_skips: Map.put(state.pending_skips, preset, reason)})
    {Map.put(event, :persisted, not is_map_key(state.pending_skips, preset)), state}
  end

  defp persist(%{event: :preset, file: file, locked: locked?} = event, state)
       when is_binary(file) and is_boolean(locked?) do
    locked = if locked?, do: file, else: nil
    state = flush_skips(state)

    with true <- locked != state.locked,
         {:ok, _settings} <- Store.update(state.store, %{locked: locked}) do
      {event, %{state | locked: locked}}
    else
      false ->
        {event, state}

      {:error, reason} ->
        Logger.warning("MilkDrop: could not save the preset lock: #{inspect(reason)}")
        {event, state}
    end
  end

  defp persist(event, state), do: {event, state}

  # Skips the Store refused (it is down) stay pending and are retried on
  # the next skip/preset event or `:retry_skips` timer; the first refusal
  # ends the pass, since the rest would be refused too.
  defp flush_skips(%{pending_skips: pending} = state) when map_size(pending) == 0, do: state

  defp flush_skips(state) do
    pending =
      Enum.reduce_while(state.pending_skips, state.pending_skips, fn {preset, reason}, acc ->
        case Store.skip(state.store, state.version, preset, reason) do
          :ok -> {:cont, Map.delete(acc, preset)}
          {:error, _} -> {:halt, acc}
        end
      end)

    schedule_skip_retry(%{state | pending_skips: pending})
  end

  defp schedule_skip_retry(%{pending_skips: pending} = state) when map_size(pending) == 0,
    do: state

  defp schedule_skip_retry(%{skip_timer: nil} = state),
    do: %{state | skip_timer: Process.send_after(self(), :retry_skips, state.skip_retry_ms)}

  defp schedule_skip_retry(state), do: state

  defp validate(config) do
    cond do
      not valid_mode?(config.mode) -> {:error, {:invalid_mode, config.mode}}
      not valid_ladder?(config.ladder) -> {:error, {:invalid_ladder, config.ladder}}
      not valid_card?(config.card) -> {:error, {:invalid_card, config.card}}
      not valid_connector?(config.connector) -> {:error, {:invalid_connector, config.connector}}
      true -> :ok
    end
  end

  defp valid_mode?(%{width: w, height: h} = mode)
       when is_integer(w) and w > 0 and is_integer(h) and h > 0 do
    case Map.get(mode, :refresh) do
      nil -> true
      r -> is_number(r) and r > 0
    end
  end

  defp valid_mode?(_mode), do: false

  defp valid_card?(nil), do: true

  defp valid_card?(path) when is_binary(path),
    do: Path.type(path) == :absolute and not String.contains?(path, ["\n", "\r", <<0>>])

  defp valid_card?(_path), do: false

  defp valid_connector?(nil), do: true
  defp valid_connector?(name) when is_binary(name), do: name =~ @connector_re
  defp valid_connector?(_name), do: false

  defp valid_ladder?([_ | _] = ladder),
    do: Enum.all?(ladder, &(is_binary(&1) and &1 =~ @resolution_re))

  defp valid_ladder?(_ladder), do: false

  defp format_mode(%{width: w, height: h} = mode) do
    case Map.get(mode, :refresh) do
      nil -> "#{w}x#{h}"
      r -> "#{w}x#{h}@#{format_refresh(r)}"
    end
  end

  defp format_refresh(r) when is_integer(r), do: Integer.to_string(r)
  defp format_refresh(r) when is_float(r), do: :erlang.float_to_binary(r, [:short])

  # Names with a line break can't be expressed in the file; the pack has none.
  defp write_skip_file(path, skipped) do
    body =
      skipped
      |> Map.keys()
      |> Enum.reject(&String.contains?(&1, ["\n", "\r"]))
      |> Enum.sort()
      |> Enum.map(&[&1, "\n"])

    case File.write(path, body) do
      :ok -> :ok
      {:error, reason} -> {:error, {:io, reason}}
    end
  end

  defp open_port(binary, args) do
    if File.regular?(binary) do
      {:ok,
       Port.open({:spawn_executable, String.to_charlist(binary)}, [
         :binary,
         :exit_status,
         {:line, @line_max},
         {:args, args}
       ])}
    else
      {:error, {:binary_missing, binary}}
    end
  rescue
    e in ErlangError -> {:error, {:spawn_failed, e.original}}
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      nil -> nil
    end
  end

  # A process outside this server, so it runs however the server ends (a
  # `:kill` included). Closing the port only closes the renderer's stdin;
  # one that does not exit on EOF would keep DRM master, so it is SIGKILLed
  # after a grace period if its pid is still alive. `:renderer_exited`
  # (sent before the server stops) means there is nothing to kill, so a
  # recycled pid is not. Once the renderer is known gone the owner is told
  # (`{:milkdrop_reaped, server}`). It traps exits so that its supervisor's
  # shutdown kills a still-running renderer rather than abandoning it. It
  # also deletes the skip file, last, once the renderer is dead or gone.
  defp start_reaper(task_sup, owner, grace_ms, skip_file) do
    server = self()

    case Task.Supervisor.start_child(
           task_sup,
           fn ->
             Process.flag(:trap_exit, true)

             try do
               if reap(Process.monitor(server), grace_ms) == :gone,
                 do: send(owner, {:milkdrop_reaped, server})
             after
               _ = File.rm(skip_file)
             end
           end,
           shutdown: @reaper_shutdown_ms
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:reaper, reason}}
    end
  catch
    :exit, reason -> {:error, {:reaper, reason}}
  end

  # `:gone` once the renderer is known not to run any more, `:unknown`
  # when that could not be confirmed.
  defp reap(ref, grace_ms) do
    receive do
      {:os_pid, os_pid} -> watch(ref, os_pid, grace_ms)
      :renderer_exited -> :gone
      {:DOWN, ^ref, :process, _pid, _reason} -> :unknown
      {:EXIT, _from, reason} -> shutdown_before_spawn(ref, reason)
    end
  end

  # Shut down while the server may still be spawning the renderer: its
  # pid (or the news there is none) follows at once, or the server died.
  @spec shutdown_before_spawn(reference(), term()) :: no_return()
  defp shutdown_before_spawn(ref, reason) do
    receive do
      {:os_pid, os_pid} -> reaper_shutdown(os_pid, reason)
      :renderer_exited -> Kernel.exit(reason)
      {:DOWN, ^ref, :process, _pid, _reason} -> Kernel.exit(reason)
    after
      @kill_confirm_ms -> Kernel.exit(reason)
    end
  end

  defp watch(ref, os_pid, grace_ms) do
    receive do
      :renderer_exited ->
        :gone

      {:DOWN, ^ref, :process, _pid, _reason} ->
        grace(os_pid, grace_ms)

      {:EXIT, _from, reason} ->
        reaper_shutdown(os_pid, reason)
    end
  end

  # The renderer may exit on its own (EOF) during the grace period; past it,
  # it is SIGKILLed and awaited.
  defp grace(os_pid, grace_ms) do
    with :alive <- await_gone(os_pid, grace_ms, &reaper_shutdown/2),
         :ok <- kill_if_alive(os_pid, "it outlived its port"),
         :alive <- await_gone(os_pid, @kill_confirm_ms, &reaper_shutdown/2) do
      Logger.warning(
        "MilkDrop renderer #{os_pid} still running #{@kill_confirm_ms} ms after SIGKILL"
      )

      :unknown
    end
  end

  # Exits only once the renderer is gone (or 1 s after the SIGKILL), so
  # its supervisor's shutdown completes with DRM master let go.
  defp reaper_shutdown(os_pid, reason) do
    kill_if_alive(os_pid, "its reaper was shut down")
    _ = await_gone(os_pid, @kill_confirm_ms)
    Kernel.exit(reason)
  end

  # Polls /proc until the renderer is gone (`:gone`) or `timeout_ms` passed
  # (`:alive`). With `on_exit`, an `{:EXIT, _, reason}` meanwhile calls it.
  defp await_gone(os_pid, timeout_ms, on_exit \\ nil) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    await_gone_until(os_pid, deadline, on_exit)
  end

  defp await_gone_until(os_pid, deadline, on_exit) do
    left = deadline - System.monotonic_time(:millisecond)

    cond do
      not alive?(os_pid) ->
        :gone

      left <= 0 ->
        :alive

      is_nil(on_exit) ->
        Process.sleep(min(@reap_poll_ms, left))
        await_gone_until(os_pid, deadline, on_exit)

      true ->
        receive do
          {:EXIT, _from, reason} -> on_exit.(os_pid, reason)
        after
          min(@reap_poll_ms, left) -> await_gone_until(os_pid, deadline, on_exit)
        end
    end
  end

  defp kill_if_alive(os_pid, why) do
    if alive?(os_pid) do
      Logger.warning("MilkDrop renderer #{os_pid} still running and #{why}; killing it")
      kill(os_pid)
    end

    :ok
  end

  # A zombie has closed its files (DRM master included) and only waits to
  # be reaped by erl_child_setup.
  defp alive?(os_pid) do
    case File.read("/proc/#{os_pid}/stat") do
      {:ok, stat} ->
        state = stat |> String.split(") ") |> List.last() |> String.first()
        state not in ["Z", "X"]

      {:error, _} ->
        false
    end
  end

  # `os_pid` is the integer from Port.info/2; nothing user-controlled
  # reaches the shell.
  defp kill(os_pid) when is_integer(os_pid) do
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
    _ = :os.cmd(~c"kill -9 #{os_pid} 2>/dev/null")
    :ok
  end
end
