defmodule UniversalProxy.Cec.Monitor do
  @moduledoc """
  Keeps one `cec-ctl -v -m` running per adapter and turns its stdout into
  `{:cec_event, dev, record}` broadcasts on the `"cec:events"` PubSub topic.

  Monitor mode is a separate file handle on `/dev/cecN` from the one-shot
  commands, so both coexist: the monitor sees every message the adapter
  receives (directed at us, or broadcast) plus state-change events, including
  our own transmits and their replies.

  cec-ctl runs under a linked `MuonTrap.Daemon` whose `:logger_fun` hands
  each stdout line back here. cec-ctl ignores stdin, so closing a plain Port
  leaves it running (at least until its next write hits the closed pipe);
  the muontrap wrapper kills it whenever its Daemon goes down, including
  when this process is killed and `terminate/2` never runs. If cec-ctl exits on its own (adapter unbound, crash) the Daemon
  stops and is restarted with a capped backoff.
  """

  use GenServer, restart: :transient

  require Logger

  alias UniversalProxy.Cec.{Ctl, Parser}

  @topic "cec:events"
  @initial_backoff_ms 2_000
  @max_backoff_ms 60_000

  defstruct [:dev, :daemon, :ref, :pubsub, :binary, parser: nil, backoff: @initial_backoff_ms]

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
  def handle_info({:cec_line, ref, line}, %{ref: ref} = state) do
    {parser, records} = Parser.feed(state.parser, line)
    Enum.each(records, &broadcast(state, &1))
    {:noreply, %{state | parser: parser}}
  end

  def handle_info({:EXIT, daemon, reason}, %{daemon: daemon} = state) do
    Logger.warning(
      "cec-ctl monitor for #{state.dev} exited (#{inspect(reason)}); " <>
        "retrying in #{state.backoff} ms"
    )

    Process.send_after(self(), :reopen, state.backoff)

    {:noreply, %{state | daemon: nil, ref: nil, backoff: min(state.backoff * 2, @max_backoff_ms)}}
  end

  def handle_info(:reopen, %{daemon: nil} = state), do: {:noreply, open(state)}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{daemon: daemon}) when is_pid(daemon) do
    GenServer.stop(daemon)
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── private ───────────────────────────────────────────────────────────

  defp open(state) do
    me = self()
    ref = make_ref()

    {:ok, daemon} =
      MuonTrap.Daemon.start_link(state.binary, Ctl.monitor_args(state.dev),
        logger_fun: &send(me, {:cec_line, ref, &1}),
        exit_status_to_reason: &{:exit_status, &1}
      )

    Logger.info("cec-ctl monitor started for #{state.dev} (os pid #{inspect(os_pid(daemon))})")
    %{state | daemon: daemon, ref: ref, parser: Parser.new()}
  end

  defp os_pid(daemon) do
    MuonTrap.Daemon.os_pid(daemon)
  catch
    :exit, _ -> :error
  end

  defp broadcast(state, record) do
    Phoenix.PubSub.broadcast(state.pubsub, @topic, {:cec_event, state.dev, record})
  end
end
