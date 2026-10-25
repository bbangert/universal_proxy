defmodule UniversalProxy.Cec.Server do
  @moduledoc """
  Owns the CEC adapter inventory: discovers `/dev/cecN`, claims a Playback
  Device logical address on each, learns its physical address, runs a
  `UniversalProxy.Cec.Monitor` per adapter, and tracks what is known about
  the device on the other end of each HDMI link (the AV receiver at logical
  address 5, by default).

  Commands themselves (`UniversalProxy.Cec.one_touch_play/1` and friends)
  run in the *caller's* process with a short `get_adapter/2` lookup here, so
  a slow receiver never blocks this server or the hotplug scan.

  ## Auto-wake

  Subscribed to the Sendspin state topic: a `stream_start` on an output whose
  ALSA card is the one paired with an adapter fires One Touch Play (Image
  View On + Active Source), waking a receiver in standby and switching it to
  the Pi's input before audio hits the link. Off per-install via
  `auto_wake: false` in the `UniversalProxy.Cec` env.

  Dependencies are injectable through `start_link/1` opts so host tests run
  without cec-ctl or sysfs: `:ctl_module`, `:enumerate` (a 0-arity fun),
  `:output_lookup` (key -> `{:ok, %{card_index: n}}`), `:monitor?`.
  """

  use GenServer

  require Logger

  alias UniversalProxy.Cec.{Ctl, Enumerate, Monitor, Parser}

  @pubsub UniversalProxy.PubSub
  @audio_topic "sendspin:state"
  @default_scan_ms 10_000

  @type receiver :: %{
          power: :on | :standby | :to_on | :to_standby | :unknown,
          volume: 0..100 | nil,
          muted: boolean() | nil,
          updated_at: DateTime.t() | nil
        }

  @type adapter :: %{
          dev: String.t(),
          index: non_neg_integer(),
          hdmi_device: String.t() | nil,
          card_index: non_neg_integer() | nil,
          phys_addr: String.t() | nil,
          logical_address: 0..15 | nil,
          claimed?: boolean(),
          receiver: receiver()
        }

  defstruct adapters: %{},
            monitors: %{},
            ctl: Ctl,
            enumerate: nil,
            output_lookup: nil,
            osd_name: "Universal Proxy",
            auto_wake: true,
            receiver_la: 5,
            scan_ms: @default_scan_ms,
            monitor?: true,
            pubsub: @pubsub,
            task_sup: UniversalProxy.TaskSupervisor

  # ── API ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec list_adapters(GenServer.server()) :: [adapter()]
  def list_adapters(server \\ __MODULE__), do: GenServer.call(server, :list_adapters)

  @spec get_adapter(GenServer.server(), String.t()) :: {:ok, adapter()} | :error
  def get_adapter(server \\ __MODULE__, dev), do: GenServer.call(server, {:get_adapter, dev})

  @doc "Adapter paired with an ALSA card index (via the shared HDMI sysfs node)."
  @spec adapter_for_card(GenServer.server(), non_neg_integer()) :: {:ok, adapter()} | :error
  def adapter_for_card(server \\ __MODULE__, card_index),
    do: GenServer.call(server, {:adapter_for_card, card_index})

  @doc "Record something learned about the far end (from a one-shot reply)."
  @spec note_receiver(GenServer.server(), String.t(), map()) :: :ok
  def note_receiver(server \\ __MODULE__, dev, partial) when is_map(partial),
    do: GenServer.cast(server, {:note_receiver, dev, partial})

  @doc "Re-run discovery now (tests, or after a manual cable swap)."
  @spec rescan(GenServer.server()) :: :ok
  def rescan(server \\ __MODULE__), do: GenServer.call(server, :rescan)

  @doc "Receiver logical address commands are sent to."
  @spec receiver_la(GenServer.server()) :: 0..15
  def receiver_la(server \\ __MODULE__), do: GenServer.call(server, :receiver_la)

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    env = Application.get_env(:universal_proxy, UniversalProxy.Cec, [])
    get = fn key, default -> Keyword.get(opts, key, Keyword.get(env, key, default)) end

    state = %__MODULE__{
      ctl: get.(:ctl_module, Ctl),
      enumerate: Keyword.get(opts, :enumerate, &Enumerate.list/0),
      output_lookup: Keyword.get(opts, :output_lookup, &UniversalProxy.Audio.get_output/1),
      osd_name: get.(:osd_name, "Universal Proxy"),
      auto_wake: get.(:auto_wake, true),
      receiver_la: get.(:receiver_la, 5),
      scan_ms: get.(:scan_interval_ms, @default_scan_ms),
      monitor?: Keyword.get(opts, :monitor?, true),
      pubsub: Keyword.get(opts, :pubsub, @pubsub),
      task_sup: Keyword.get(opts, :task_supervisor, UniversalProxy.TaskSupervisor)
    }

    Phoenix.PubSub.subscribe(state.pubsub, @audio_topic)
    Phoenix.PubSub.subscribe(state.pubsub, Monitor.topic())
    send(self(), :scan)
    {:ok, state}
  end

  @impl true
  def handle_call(:list_adapters, _from, state) do
    {:reply, state.adapters |> Map.values() |> Enum.sort_by(& &1.index), state}
  end

  def handle_call({:get_adapter, dev}, _from, state),
    do: {:reply, Map.fetch(state.adapters, dev), state}

  def handle_call({:adapter_for_card, card_index}, _from, state) do
    {:reply, find_by_card(state, card_index), state}
  end

  def handle_call(:rescan, _from, state), do: {:reply, :ok, scan(state)}
  def handle_call(:receiver_la, _from, state), do: {:reply, state.receiver_la, state}

  @impl true
  def handle_cast({:note_receiver, dev, partial}, state) do
    {:noreply, update_receiver(state, dev, partial)}
  end

  @impl true
  def handle_info(:scan, state) do
    Process.send_after(self(), :scan, state.scan_ms)
    {:noreply, scan(state)}
  end

  # A Sendspin stream starting on an HDMI output: wake + select the receiver.
  def handle_info({:sendspin_state, key, %{event: "stream_start"}}, state) do
    if state.auto_wake do
      with {:ok, %{card_index: card}} <- state.output_lookup.(key),
           {:ok, adapter} <- find_by_card(state, card) do
        Logger.info("CEC: stream starting on card #{card}; One Touch Play via #{adapter.dev}")
        ctl = state.ctl
        la = state.receiver_la

        Task.Supervisor.start_child(state.task_sup, fn ->
          UniversalProxy.Cec.one_touch_play(adapter, ctl: ctl, receiver_la: la)
        end)
      end
    end

    {:noreply, state}
  end

  def handle_info({:sendspin_state, _key, _event}, state), do: {:noreply, state}

  def handle_info({:cec_event, dev, %{type: :event, kind: :state_change, phys_addr: pa}}, state) do
    {:noreply, update_adapter(state, dev, &%{&1 | phys_addr: pa})}
  end

  def handle_info({:cec_event, dev, %{type: :message, direction: :received} = msg}, state) do
    {:noreply, apply_message(state, dev, msg)}
  end

  def handle_info({:cec_event, _dev, _record}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    monitors = state.monitors |> Enum.reject(fn {_dev, p} -> p == pid end) |> Map.new()
    {:noreply, %{state | monitors: monitors}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── discovery ─────────────────────────────────────────────────────────

  defp scan(state) do
    present = safe_enumerate(state)
    known = state.adapters

    removed = Map.keys(known) -- Map.keys(present)
    state = Enum.reduce(removed, state, &remove_adapter(&2, &1))

    Enum.reduce(present, state, fn {dev, info}, acc ->
      case Map.fetch(acc.adapters, dev) do
        {:ok, existing} ->
          # Keep what we learned; refresh the sysfs-derived pairing.
          put_adapter(acc, %{
            existing
            | hdmi_device: info.hdmi_device,
              card_index: info.card_index
          })

        :error ->
          add_adapter(acc, info)
      end
    end)
  end

  defp safe_enumerate(state) do
    state.enumerate.()
  rescue
    e ->
      Logger.warning("CEC enumerate raised: #{Exception.message(e)}")
      %{}
  end

  defp add_adapter(state, info) do
    adapter =
      info
      |> Map.merge(%{
        phys_addr: nil,
        logical_address: nil,
        claimed?: false,
        receiver: %{power: :unknown, volume: nil, muted: nil, updated_at: nil}
      })
      |> claim(state)

    state = put_adapter(state, adapter)
    if state.monitor?, do: start_monitor(state, adapter.dev), else: state
  end

  defp claim(adapter, state) do
    dev = adapter.dev

    claimed? =
      case state.ctl.run(Ctl.claim_playback_args(dev, state.osd_name), []) do
        {:ok, _} ->
          true

        {:error, reason} ->
          Logger.warning("CEC: claiming a playback address on #{dev} failed: #{inspect(reason)}")
          false
      end

    info =
      case state.ctl.run(Ctl.driver_info_args(dev), []) do
        {:ok, out} -> Parser.driver_info(out)
        {:error, _} -> %{phys_addr: nil, logical_address: nil}
      end

    Logger.info(
      "CEC: #{dev} (#{adapter.hdmi_device || "?"}, card #{inspect(adapter.card_index)}) " <>
        "phys #{inspect(info.phys_addr)} logical #{inspect(info.logical_address)}"
    )

    %{
      adapter
      | claimed?: claimed?,
        phys_addr: info.phys_addr,
        logical_address: info.logical_address
    }
  end

  defp start_monitor(state, dev) do
    case DynamicSupervisor.start_child(
           UniversalProxy.Cec.MonitorSupervisor,
           {Monitor, dev: dev, pubsub: state.pubsub}
         ) do
      {:ok, pid} ->
        Process.monitor(pid)
        %{state | monitors: Map.put(state.monitors, dev, pid)}

      {:error, reason} ->
        Logger.warning("CEC: monitor for #{dev} not started: #{inspect(reason)}")
        state
    end
  end

  defp remove_adapter(state, dev) do
    Logger.info("CEC: #{dev} gone")

    case Map.pop(state.monitors, dev) do
      {nil, monitors} ->
        %{state | adapters: Map.delete(state.adapters, dev), monitors: monitors}

      {pid, monitors} ->
        _ = DynamicSupervisor.terminate_child(UniversalProxy.Cec.MonitorSupervisor, pid)
        %{state | adapters: Map.delete(state.adapters, dev), monitors: monitors}
    end
  end

  # ── state updates ─────────────────────────────────────────────────────

  defp apply_message(state, dev, %{opcode: "REPORT_POWER_STATUS"} = msg),
    do: update_receiver(state, dev, %{power: Parser.power_state(msg)})

  defp apply_message(state, dev, %{opcode: "REPORT_AUDIO_STATUS"} = msg),
    do: update_receiver(state, dev, Parser.audio_status(msg))

  defp apply_message(state, dev, %{opcode: "STANDBY"}),
    do: update_receiver(state, dev, %{power: :standby})

  defp apply_message(state, _dev, _msg), do: state

  defp update_receiver(state, dev, partial) do
    update_adapter(state, dev, fn adapter ->
      receiver =
        adapter.receiver
        |> Map.merge(Map.take(partial, [:power, :volume, :muted]))
        |> Map.put(:updated_at, DateTime.utc_now())

      %{adapter | receiver: receiver}
    end)
  end

  defp update_adapter(state, dev, fun) do
    case Map.fetch(state.adapters, dev) do
      {:ok, adapter} -> put_adapter(state, fun.(adapter))
      :error -> state
    end
  end

  defp put_adapter(state, adapter),
    do: %{state | adapters: Map.put(state.adapters, adapter.dev, adapter)}

  defp find_by_card(_state, nil), do: :error

  defp find_by_card(state, card_index) do
    case Enum.find(Map.values(state.adapters), &(&1.card_index == card_index)) do
      nil -> :error
      adapter -> {:ok, adapter}
    end
  end
end
