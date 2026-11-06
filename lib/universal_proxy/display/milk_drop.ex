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

  However this process ends — stopped, its owner gone, crashed or killed —
  a reaper task under `UniversalProxy.TaskSupervisor` that monitors it
  SIGKILLs a renderer still running `:kill_grace_ms` later: one that
  ignores EOF or has stopped reading would otherwise keep DRM master.

  ## Options

    * `:owner` — pid to report to (default: the caller);
    * `:mode` — `%{width:, height:, refresh:}`, the output mode to keep
      (required);
    * `:pack_dir`, `:pack_version` — the extracted pack and its version
      (required; the version keys persisted skips);
    * `:ladder` — internal resolutions, highest first (default
      `default_ladder/1` for this target);
    * `:ring_path` — the Sendspin player's PCM tap ring (optional: without
      it the renderer draws silence);
    * `:settings`, `:skipped` — default to `UniversalProxy.MilkDrop.Store`'s
      settings and skip list for `:pack_version`; `:store` names the Store;
    * `:skip_file` — where the skip list is written for the renderer
      (default `<tmp>/up-milkdrop-skip.txt`; deleted on stop);
    * `:binary` — the renderer (default `default_binary/0`);
    * `:kill_grace_ms` — how long a renderer that outlives its closed stdin
      may run before it is SIGKILLed (default 2000).

  ## Renderer CLI contract

      milkdrop_renderer --mode 1280x720@60 --pack-dir DIR
                        --ladder 640x360,480x270 --rotate-s 20
                        --skip-file PATH
                        [--high-frequency] [--locked FILE] [--pcm-ring PATH]

    * `--mode` — the CRTC mode to present on (reused without a modeset when
      it is already current);
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
      the scanout), drop master; card0 stays open;
    * `{"cmd":"exit"}` — close card0, report `exiting`, exit 0;
    * `{"cmd":"next"}`, `{"cmd":"prev"}` — change preset (with history);
    * `{"cmd":"lock"}`, `{"cmd":"unlock"}` — hold / resume rotation on the
      current preset;
    * `{"cmd":"set_rotate","value":N}` — rotation interval in seconds;
    * `{"cmd":"set_high_frequency","value":B}` — include `high_frequency/`.

  Events (stdout), forwarded with atom keys and an atom `:event`:

    * `{"event":"prepared"}` — GL is up and the first preset warmed, not
      yet master;
    * `{"event":"presenting"}` — `take` done, frames are on screen;
    * `{"event":"released"}` — `release` done, master dropped;
    * `{"event":"preset","file":F,"locked":B,...}` — preset `F` is showing;
    * `{"event":"skip","preset":F,"reason":R}` — `F` cannot be drawn
      (persisted to the Store for this pack version);
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

  @type mode :: %{width: pos_integer(), height: pos_integer(), refresh: number()}

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

  @doc "Stop presenting and drop DRM master, keeping card0 open."
  @spec release(GenServer.server()) :: :ok
  def release(server), do: command(server, %{cmd: "release"})

  @doc "Ask the renderer to close card0 and exit."
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
  `:pack_dir`, `:ladder`, `:skip_file`, `:settings` and an optional
  `:ring_path`.
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
      if(config[:ring_path], do: ["--pcm-ring", config.ring_path], else: [])
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
      settings: settings,
      skip_file:
        Keyword.get_lazy(opts, :skip_file, fn ->
          Path.join(System.tmp_dir!(), "up-milkdrop-skip.txt")
        end)
    }

    binary = Keyword.get_lazy(opts, :binary, &default_binary/0)

    kill_grace_ms = Keyword.get(opts, :kill_grace_ms, @kill_grace_ms)

    with :ok <- validate(config),
         :ok <- write_skip_file(config.skip_file, skipped),
         {:ok, port} <- open_port(binary, args(config)),
         os_pid = os_pid(port),
         {:ok, reaper} <- start_reaper(os_pid, kill_grace_ms) do
      {:ok,
       %{
         owner: owner,
         owner_ref: Process.monitor(owner),
         port: port,
         os_pid: os_pid,
         reaper: reaper,
         store: store,
         version: version,
         locked: Map.get(settings, :locked),
         skip_file: config.skip_file,
         discarding: false
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
    if state.reaper, do: send(state.reaper, :renderer_exited)
    send(state.owner, {:milkdrop_exit, self(), status})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # The port closes with this process; the reaper handles a renderer that
  # outlives it. A killed server leaves the skip file for the next start
  # to overwrite.
  @impl true
  def terminate(_reason, state), do: File.rm(state.skip_file)

  # -- Private --

  defp handle_line(line, state) do
    case decode_event(line) do
      {:ok, event} ->
        state = persist(event, state)
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
    _ = Store.skip(state.store, state.version, preset, reason)
    state
  end

  defp persist(%{event: :preset, file: file, locked: locked?}, state)
       when is_binary(file) and is_boolean(locked?) do
    locked = if locked?, do: file, else: nil

    with true <- locked != state.locked,
         {:ok, _settings} <- Store.update(state.store, %{locked: locked}) do
      %{state | locked: locked}
    else
      false ->
        state

      {:error, reason} ->
        Logger.warning("MilkDrop: could not save the preset lock: #{inspect(reason)}")
        state
    end
  end

  defp persist(_event, state), do: state

  defp validate(config) do
    cond do
      not valid_mode?(config.mode) -> {:error, {:invalid_mode, config.mode}}
      not valid_ladder?(config.ladder) -> {:error, {:invalid_ladder, config.ladder}}
      true -> :ok
    end
  end

  defp valid_mode?(%{width: w, height: h, refresh: r}),
    do: is_integer(w) and w > 0 and is_integer(h) and h > 0 and is_number(r) and r > 0

  defp valid_mode?(_mode), do: false

  defp valid_ladder?([_ | _] = ladder),
    do: Enum.all?(ladder, &(is_binary(&1) and &1 =~ @resolution_re))

  defp valid_ladder?(_ladder), do: false

  defp format_mode(%{width: w, height: h, refresh: r}), do: "#{w}x#{h}@#{format_refresh(r)}"

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
  # (sent before the server stops) means there is nothing to kill.
  defp start_reaper(nil, _grace_ms), do: {:ok, nil}

  defp start_reaper(os_pid, grace_ms) do
    server = self()

    case Task.Supervisor.start_child(UniversalProxy.TaskSupervisor, fn ->
           reap(Process.monitor(server), os_pid, grace_ms)
         end) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:reaper, reason}}
    end
  catch
    :exit, reason -> {:error, {:reaper, reason}}
  end

  defp reap(ref, os_pid, grace_ms) do
    receive do
      :renderer_exited ->
        :ok

      {:DOWN, ^ref, :process, _pid, _reason} ->
        Process.sleep(grace_ms)

        if File.exists?("/proc/#{os_pid}") do
          Logger.warning("MilkDrop renderer #{os_pid} outlived its port; killing it")
          # `os_pid` is the integer from Port.info/2; nothing user-controlled
          # reaches the shell.
          # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
          _ = :os.cmd(~c"kill -9 #{os_pid} 2>/dev/null")
        end
    end
  end
end
