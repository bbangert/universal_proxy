defmodule UniversalProxy.Cec.Monitor do
  @moduledoc """
  Keeps one `cec-ctl -m` running per adapter and turns its stdout into
  `{:cec_event, dev, record}` broadcasts on the `"cec:events"` PubSub topic.

  Monitor mode is a separate file handle on `/dev/cecN` from the one-shot
  commands, so both coexist: the monitor sees every message the adapter
  receives (directed at us, or broadcast) plus state-change events, including
  our own transmits and their replies.

  Raw `Port` rather than `MuonTrap.Daemon` because the output has to be
  parsed, not logged. cec-ctl ignores stdin, so closing the port does not
  end it; `terminate/2` kills the OS pid explicitly, the way
  `UniversalProxy.Audio.Player` does for the player binary. If cec-ctl
  exits on its own (adapter unbound, crash) the port is reopened with a
  capped backoff.
  """

  use GenServer, restart: :transient

  require Logger

  alias UniversalProxy.Cec.{Ctl, Parser}

  @topic "cec:events"
  @initial_backoff_ms 2_000
  @max_backoff_ms 60_000

  defstruct [:dev, :port, :os_pid, :pubsub, :binary, parser: nil, backoff: @initial_backoff_ms]

  @doc "PubSub topic the parsed records are broadcast on."
  @spec topic() :: String.t()
  def topic, do: @topic

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      dev: Keyword.fetch!(opts, :dev),
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      binary: Keyword.get(opts, :binary) || System.find_executable(Ctl.binary()),
      parser: Parser.new()
    }

    if is_nil(state.binary) do
      {:stop, :cec_ctl_missing}
    else
      {:ok, open(state)}
    end
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    {parser, records} = Parser.feed(state.parser, line)
    Enum.each(records, &broadcast(state, &1))
    {:noreply, %{state | parser: parser}}
  end

  def handle_info({port, {:data, {:noeol, _partial}}}, %{port: port} = state) do
    # Oversized line: drop the fragment; the parser is line-anchored anyway.
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "cec-ctl monitor for #{state.dev} exited (#{status}); retrying in #{state.backoff} ms"
    )

    Process.send_after(self(), :reopen, state.backoff)

    {:noreply,
     %{state | port: nil, os_pid: nil, backoff: min(state.backoff * 2, @max_backoff_ms)}}
  end

  def handle_info(:reopen, %{port: nil} = state), do: {:noreply, open(state)}

  def handle_info({:EXIT, port, _reason}, %{port: port} = state), do: {:noreply, state}
  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    force_kill(state)
    :ok
  end

  # ── private ───────────────────────────────────────────────────────────

  defp open(state) do
    port =
      Port.open(
        {:spawn_executable, String.to_charlist(state.binary)},
        [:binary, :exit_status, {:line, 1024}, {:args, Ctl.monitor_args(state.dev)}]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    Logger.info("cec-ctl monitor started for #{state.dev} (os pid #{inspect(os_pid)})")
    %{state | port: port, os_pid: os_pid, parser: Parser.new()}
  end

  defp broadcast(state, record) do
    Phoenix.PubSub.broadcast(state.pubsub, @topic, {:cec_event, state.dev, record})
  end

  defp force_kill(%{os_pid: nil}), do: :ok

  defp force_kill(%{os_pid: pid, port: port}) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    # Integer OS pid from Port.info/2 — nothing user-controlled reaches the shell.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeExec
    _ = :os.cmd(~c"kill -9 #{pid}")
    :ok
  end
end
