defmodule UniversalProxy.Cec.VolumeLink do
  @moduledoc """
  Keeps an HDMI audio output's volume and mute in step with the receiver
  that plays it, both ways.

  An output is *linked* while the CEC adapter paired with its ALSA card is
  running, the receiver is present, on and reporting a volume, and the
  output's `cec_volume` setting is on (`UniversalProxy.Cec.volume_link?/2`).
  It stays linked until the receiver reports standby, the adapter or the
  output goes away, the setting is turned off, or the receiver stops
  answering: `:fail_unlink` (3) polls or runs in a row that the receiver
  didn't acknowledge or reply to (`:nack`, `:timeout`, `:max_retries`, or a
  crashed run), or answered without a volume (`:unknown_volume`, or a
  Feature Abort of `<Give Audio Status>`). An output
  linked to a receiver it can't control would otherwise stay at unity
  gain. Errors on our side of the bus (`:not_configured` while the
  adapter re-acquires its address after a hotplug, `:busy`,
  `:cec_unavailable`, ...) say nothing about the receiver and leave the
  count alone; a stalled run read the volume back, so it counts as an
  answer. A silent receiver's adapter relinks only once a probe gets an
  answer again, not on `Cec.Server`'s record, which still holds the last
  report. A receiver record that is merely cleared
  (`UniversalProxy.Cec.Server` drops it when the HDMI link changes) keeps
  the link and the last known values until the next poll.

    * **Linking** puts the output's player in external-volume mode
      (`UniversalProxy.Audio.set_volume_external/2`: unity gain, volume and
      mute still reported) and adopts the receiver's volume and mute into
      the output. The receiver wins: the stored software volume is never
      sent to it. **Unlinking** turns external mode off again, and software
      volume resumes at the last value shown; a run in progress is stopped.
    * **Output to receiver**: a player `volume` or `mute` event (from the
      Sendspin server or `UniversalProxy.Audio.update_config/2`) steps the
      receiver there with `UniversalProxy.Cec.set_volume/3` and
      `set_muted/3`, in a task, one run per adapter at a time. The volume
      is capped at the output's `cec_volume_max`. A value that arrives
      during a run or a poll is applied when it ends, against what the
      receiver then reports (latest wins). Receivers commonly move several
      units per press: each walk gets the step the previous one learned
      and the cap, and settles on the nearest reachable volume, so a
      target within half a step of the receiver's volume counts as
      reached. Once nothing is
      left to do, whatever the receiver ended at is written back to the
      output if it differs (the cap, a stall, a failure), so the server and
      the UI never show a volume the receiver isn't at.
    * **Receiver to output**: receivers don't report knob or remote changes
      by themselves, so a linked receiver is asked for its audio status
      every `:poll_ms` while no run is in progress; any report
      `UniversalProxy.Cec.Server` records counts as well. A change is
      written to the output as is (the cap only limits requests). Reports
      during a run and for `:settle_ms` after it are the run's own steps
      and are ignored.

  Each value written to the output comes back once as a player event, and
  is expected (for a few seconds); expected events, and events repeating
  the value already shown, never start a run. An expected echo still says
  what the player shows now (it may land after a newer request), so the
  receiver's state is written back over it if they differ. A freshly
  spawned player's startup snapshot (tagged by `UniversalProxy.Audio.Player`)
  is handled the same way: it is what the player started with, not a
  request, so a hotplug's `--initial-volume` never moves the receiver.

  Runs and polls are this process's own jobs, under `:task_supervisor`
  (`UniversalProxy.Cec.Supervisor`'s, so a subtree restart ends them).
  Each carries the generation of the link it was started for, and results
  for an earlier link are dropped.

  Receivers report neither power nor volume until asked, so an adapter
  whose output could link is probed every `:probe_ms` (power status, then
  audio status once it is on). The replies reach `Cec.Server`, and its
  `{:cec_adapters, _}` broadcast links the output. A linked receiver's power
  is checked at the same pace.

  Dependencies are injectable through `start_link/1` for host tests:
  `:list_adapters`, `:list_outputs`, `:set_volume_external` (key, bool),
  `:update_config` (key, map), `:set_volume` (dev, target, opts), `:set_muted`
  (dev, bool), `:audio_status` (dev), `:power_status` (dev), `:pubsub`,
  `:task_supervisor`, `:default` (the `volume_link` default), `:fail_unlink`
  and the `:poll_ms`, `:probe_ms`, `:settle_ms` and `:echo_ttl_ms` intervals.
  """

  use GenServer

  require Logger

  alias UniversalProxy.{Audio, Cec}

  @pubsub UniversalProxy.PubSub
  @state_topic "sendspin:state"
  @added_topic "sendspin:output_added"
  @removed_topic "sendspin:output_removed"
  @default_poll_ms 3_000
  @default_probe_ms 10_000
  @default_settle_ms 1_000
  @default_fail_unlink 3
  @default_echo_ttl_ms 5_000
  @fields [:volume, :muted]

  defstruct adapters: %{},
            outputs: %{},
            links: %{},
            busy: %{},
            timers: %{},
            power_at: %{},
            lost: MapSet.new(),
            gen: 0,
            funs: %{},
            default: true,
            poll_ms: @default_poll_ms,
            probe_ms: @default_probe_ms,
            settle_ms: @default_settle_ms,
            fail_unlink: @default_fail_unlink,
            echo_ttl_ms: @default_echo_ttl_ms,
            pubsub: @pubsub,
            task_sup: UniversalProxy.Cec.TaskSupervisor

  # ── API ───────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Output keys currently linked, by adapter device path."
  @spec links(GenServer.server()) :: %{String.t() => Audio.key()}
  def links(server \\ __MODULE__), do: GenServer.call(server, :links)

  # ── GenServer ─────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    env = Application.get_env(:universal_proxy, Cec, [])

    funs = %{
      list_adapters: Keyword.get(opts, :list_adapters, &Cec.list_adapters/0),
      list_outputs: Keyword.get(opts, :list_outputs, &Audio.list_outputs/0),
      set_volume_external: Keyword.get(opts, :set_volume_external, &Audio.set_volume_external/2),
      update_config: Keyword.get(opts, :update_config, &Audio.update_config/2),
      set_volume: Keyword.get(opts, :set_volume, &Cec.set_volume/3),
      set_muted: Keyword.get(opts, :set_muted, &Cec.set_muted(&1, &2)),
      audio_status: Keyword.get(opts, :audio_status, &Cec.audio_status(&1)),
      power_status: Keyword.get(opts, :power_status, &Cec.power_status(&1))
    }

    state = %__MODULE__{
      funs: funs,
      default: Keyword.get(opts, :default, Keyword.get(env, :volume_link, true)),
      poll_ms: Keyword.get(opts, :poll_ms, Keyword.get(env, :volume_poll_ms, @default_poll_ms)),
      probe_ms: Keyword.get(opts, :probe_ms, @default_probe_ms),
      settle_ms: Keyword.get(opts, :settle_ms, @default_settle_ms),
      fail_unlink: Keyword.get(opts, :fail_unlink, @default_fail_unlink),
      echo_ttl_ms: Keyword.get(opts, :echo_ttl_ms, @default_echo_ttl_ms),
      pubsub: Keyword.get(opts, :pubsub, @pubsub),
      task_sup: Keyword.get(opts, :task_supervisor, UniversalProxy.Cec.TaskSupervisor)
    }

    for topic <- [Cec.topic(), @state_topic, @added_topic, @removed_topic] do
      Phoenix.PubSub.subscribe(state.pubsub, topic)
    end

    {:ok, state, {:continue, :init}}
  end

  # Subscribed first, then read, so no change slips between the two. A
  # restarted link finds players a previous incarnation left in external
  # mode; those that don't link now are handed back their volume.
  @impl true
  def handle_continue(:init, state) do
    outputs =
      for output <- safe(state.funs.list_outputs, []), into: %{}, do: {output.key, output}

    state =
      %{state | outputs: outputs, adapters: by_dev(safe(state.funs.list_adapters, []))}
      |> evaluate()

    linked = linked_keys(state)

    for {key, %{volume_external: true}} <- outputs, key not in linked do
      safe(fn -> state.funs.set_volume_external.(key, false) end, :ok)
    end

    {:noreply, state}
  end

  @impl true
  def handle_call(:links, _from, state) do
    {:reply, Map.new(state.links, fn {dev, link} -> {dev, link.key} end), state}
  end

  @impl true
  def handle_info({:cec_adapters, adapters}, state) when is_list(adapters) do
    new = by_dev(adapters)
    state = Enum.reduce(state.links, state, &broadcast_report(&2, elem(&1, 0), new))
    {:noreply, evaluate(%{state | adapters: new})}
  end

  def handle_info({:sendspin_output_added, %{key: key} = output}, state) do
    if key in linked_keys(state) do
      safe(fn -> state.funs.set_volume_external.(key, true) end, :ok)
    end

    {:noreply, evaluate(%{state | outputs: Map.put(state.outputs, key, output)})}
  end

  def handle_info({:sendspin_output_removed, %{key: key}}, state) do
    {:noreply, evaluate(%{state | outputs: Map.delete(state.outputs, key)})}
  end

  # A freshly spawned player's startup snapshot (`Audio.Player`'s
  # `startup: true`): what it was started with, not a request.
  # A new player echoes nothing written to the one before it, so the
  # snapshot also drops what was expected.
  def handle_info({:sendspin_state, key, %{event: "volume", value: v, startup: true}}, state)
      when is_integer(v) and v in 0..100 do
    {:noreply,
     state |> note_output(key, %{volume: v}) |> forget_echoes(key) |> shows(key, :volume, v)}
  end

  def handle_info({:sendspin_state, key, %{event: "mute", value: m, startup: true}}, state)
      when is_boolean(m) do
    {:noreply,
     state |> note_output(key, %{muted: m}) |> forget_echoes(key) |> shows(key, :muted, m)}
  end

  def handle_info({:sendspin_state, key, %{event: "volume", value: v}}, state)
      when is_integer(v) and v in 0..100 do
    {:noreply, state |> note_output(key, %{volume: v}) |> intent(key, :volume, v)}
  end

  def handle_info({:sendspin_state, key, %{event: "mute", value: m}}, state)
      when is_boolean(m) do
    {:noreply, state |> note_output(key, %{muted: m}) |> intent(key, :muted, m)}
  end

  def handle_info({:sendspin_state, _key, %{event: _}}, state), do: {:noreply, state}

  # A configuration write (the `cec_volume` setting among them).
  def handle_info({:sendspin_state, key, partial}, state) when is_map(partial) do
    {:noreply, state |> note_output(key, partial) |> evaluate()}
  end

  # Only the timer currently armed for `dev` counts: a cancelled one may
  # already have delivered its message.
  def handle_info({:poll, dev, token}, state) do
    case state.timers do
      %{^dev => {^token, _timer}} ->
        state = %{state | timers: Map.delete(state.timers, dev)}

        if Map.has_key?(candidates(state), dev) and not Map.has_key?(state.busy, dev),
          do: {:noreply, start_poll(state, dev)},
          else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case busy_job(state, ref) do
      nil ->
        {:noreply, state}

      {dev, job} ->
        Process.demonitor(ref, [:flush])
        {:noreply, job_done(%{state | busy: Map.delete(state.busy, dev)}, dev, job, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case busy_job(state, ref) do
      nil ->
        {:noreply, state}

      {dev, job} ->
        Logger.warning("CEC volume link: #{dev} task crashed: #{inspect(reason)}")
        {:noreply, job_done(%{state | busy: Map.delete(state.busy, dev)}, dev, job, :crashed)}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── linking ───────────────────────────────────────────────────────────

  # Unlink what no longer qualifies, link what newly does, and keep each
  # candidate adapter's poll scheduled.
  defp evaluate(state) do
    candidates = candidates(state)

    state =
      Enum.reduce(state.links, state, fn {dev, link}, acc ->
        case unlink_reason(acc, dev, link, candidates) do
          nil -> acc
          reason -> unlink(acc, dev, reason)
        end
      end)

    state =
      Enum.reduce(candidates, state, fn {dev, key}, acc ->
        if not Map.has_key?(acc.links, dev) and key not in linked_keys(acc) and
             not MapSet.member?(acc.lost, dev) and linkable?(acc.adapters[dev]),
           do: link(acc, dev, key),
           else: acc
      end)

    schedule_all(state, candidates)
  end

  # Adapters whose receiver could carry an output's volume: `%{dev => key}`.
  defp candidates(state) do
    for {dev, %{running?: true, receiver_presence: :present, card_index: card}} <- state.adapters,
        is_integer(card),
        key <- List.wrap(output_for_card(state, card)),
        into: %{},
        do: {dev, key}
  end

  defp output_for_card(state, card) do
    state.outputs
    |> Enum.sort()
    |> Enum.find_value(fn {key, output} ->
      if Map.get(output, :card_index) == card and Cec.volume_link?(output, state.default),
        do: key
    end)
  end

  # Why a link no longer holds, or nil while it does.
  defp unlink_reason(state, dev, link, candidates) do
    adapter = state.adapters[dev]
    output = state.outputs[link.key]

    cond do
      adapter == nil -> "adapter gone"
      not Map.get(adapter, :running?, false) -> "adapter stopped"
      Map.get(adapter, :receiver_presence) != :present -> "receiver absent"
      output == nil -> "output gone"
      not Cec.volume_link?(output, state.default) -> "setting off"
      Map.get(candidates, dev) != link.key -> "output changed"
      receiver(adapter).power in [:standby, :to_standby] -> "standby"
      true -> nil
    end
  end

  defp linkable?(adapter) do
    %{power: power, volume: volume} = receiver(adapter)
    power == :on and is_integer(volume)
  end

  defp link(state, dev, key) do
    %{volume: volume, muted: muted} = receiver(state.adapters[dev])
    Logger.info("CEC volume link: #{inspect(key)} follows the receiver on #{dev} (#{volume})")
    safe(fn -> state.funs.set_volume_external.(key, true) end, :ok)

    gen = state.gen + 1

    link = %{
      key: key,
      gen: gen,
      receiver: %{volume: volume, muted: muted},
      shown: %{volume: nil, muted: nil},
      pending: %{},
      echoes: [],
      quiet_until: nil,
      failures: [],
      # The receiver's volume step, as `Cec.set_volume/3` learned it.
      step: nil
    }

    state = %{state | gen: gen, links: Map.put(state.links, dev, link)}
    push(state, dev, known(link.receiver))
  end

  defp unlink(state, dev, reason) do
    %{key: key} = state.links[dev]

    Logger.info(
      "CEC volume link: #{inspect(key)} no longer follows the receiver on #{dev} (#{reason})"
    )

    safe(fn -> state.funs.set_volume_external.(key, false) end, :ok)
    stop_run(%{state | links: Map.delete(state.links, dev)}, dev)
  end

  # A run keeps pressing keys towards a target nobody wants any more: end
  # it. Each press and its readback is one adapter call, which completes
  # by itself, so the walk stops between calls. Polls only read, and their
  # results are dropped by generation.
  defp stop_run(state, dev) do
    case state.busy[dev] do
      %{kind: :step, ref: ref, pid: pid} ->
        Process.demonitor(ref, [:flush])
        _ = Task.Supervisor.terminate_child(state.task_sup, pid)
        %{state | busy: Map.delete(state.busy, dev)}

      _ ->
        state
    end
  end

  defp linked_keys(state), do: for({_dev, %{key: key}} <- state.links, do: key)

  defp link_for_key(state, key), do: Enum.find(state.links, fn {_dev, l} -> l.key == key end)

  # ── output → receiver ─────────────────────────────────────────────────

  defp intent(state, key, field, value) do
    case link_for_key(state, key) do
      nil -> state
      {dev, link} -> link_intent(state, dev, link, field, value)
    end
  end

  defp forget_echoes(state, key) do
    case link_for_key(state, key) do
      nil -> state
      {dev, _link} -> put_in(state.links[dev].echoes, [])
    end
  end

  defp shows(state, key, field, value) do
    case link_for_key(state, key) do
      nil -> state
      {dev, link} -> showing(state, dev, link, field, value)
    end
  end

  # What the player shows now without anyone asking for it (an echo, even
  # one that arrived after a newer request, or a startup snapshot): written
  # back over once the receiver's state is known.
  defp showing(state, dev, link, field, value) do
    link = put_in(link.shown[field], value)
    state = put_in(state.links[dev], link)
    if busy_step?(state, dev), do: state, else: sync_output(state, dev)
  end

  defp link_intent(state, dev, link, field, value) do
    case take_echo(link, field, value) do
      {:echo, link} ->
        showing(state, dev, link, field, value)

      {:none, %{shown: %{^field => ^value}} = link} ->
        put_in(state.links[dev], link)

      {:none, link} ->
        link = put_in(link.shown[field], value)
        state = put_in(state.links[dev], link)
        request(state, dev, field, target(state, link.key, field, value))
    end
  end

  defp target(state, key, :volume, volume) do
    case ceiling(state, key) do
      nil -> volume
      max -> min(volume, max)
    end
  end

  defp target(_state, _key, :muted, muted), do: muted

  defp ceiling(state, key) do
    case state.outputs |> Map.get(key, %{}) |> Map.get(:cec_volume_max) do
      max when is_integer(max) -> max
      _ -> nil
    end
  end

  # Receivers move several units per press, so the target may not be
  # reachable: there is when `Cec.set_volume/3`'s own walk would stop, so
  # asking again doesn't press back and forth.
  defp reached?(state, dev, :volume, target) do
    link = state.links[dev]
    volume = link.receiver.volume

    is_integer(volume) and
      Cec.next_key(volume, link.step || 1, target, ceiling(state, link.key) || 100) == nil
  end

  defp reached?(state, dev, :muted, muted), do: state.links[dev].receiver.muted == muted

  defp request(state, dev, field, target) do
    cond do
      # Compared with the receiver once the job ends, against its readback.
      Map.has_key?(state.busy, dev) ->
        put_in(state.links[dev].pending[field], target)

      not reached?(state, dev, field, target) ->
        state = put_in(state.links[dev].pending[field], target)
        start_step(state, dev)

      true ->
        state = update_in(state.links[dev].pending, &Map.delete(&1, field))
        sync_output(state, dev)
    end
  end

  # The pending targets the receiver isn't at yet.
  defp todo(state, dev) do
    for {field, target} <- state.links[dev].pending,
        not reached?(state, dev, field, target),
        into: %{},
        do: {field, target}
  end

  defp start_step(state, dev) do
    link = state.links[dev]
    targets = todo(state, dev)
    state = put_in(state.links[dev].pending, %{})

    if targets == %{} do
      sync_output(state, dev)
    else
      %{set_volume: set_volume, set_muted: set_muted} = state.funs
      walk_opts = walk_opts(link.step, ceiling(state, link.key))
      set_volume = &set_volume.(&1, &2, walk_opts)

      task =
        Task.Supervisor.async_nolink(state.task_sup, fn ->
          step(set_volume, set_muted, dev, targets)
        end)

      put_job(state, dev, task, :step)
    end
  end

  defp walk_opts(step, max) do
    Enum.reject([step: step, max: max], fn {_key, value} -> value == nil end)
  end

  # Runs in the task: mute first (one or two presses), then the walk.
  defp step(set_volume, set_muted, dev, targets) do
    {status, error} =
      case Map.fetch(targets, :muted) do
        {:ok, muted} -> step_result(set_muted.(dev, muted))
        :error -> {nil, nil}
      end

    case {error, Map.fetch(targets, :volume)} do
      {nil, {:ok, volume}} ->
        {volume_status, volume_error} = step_result(set_volume.(dev, volume))
        {:step, targets, merge_status(status, volume_status), volume_error}

      _ ->
        {:step, targets, status, error}
    end
  end

  defp step_result({:ok, status}), do: {status, nil}
  defp step_result({:error, {kind, status}}) when is_map(status), do: {status, kind}
  defp step_result({:error, reason}), do: {nil, reason}

  defp merge_status(nil, status), do: status
  defp merge_status(status, nil), do: status
  defp merge_status(a, b), do: Map.merge(a, Map.reject(b, fn {_key, value} -> value == nil end))

  # ── receiver → output ─────────────────────────────────────────────────

  # A report Cec.Server recorded: new when its timestamp moved.
  defp broadcast_report(state, dev, new_adapters) do
    old = receiver(state.adapters[dev])
    new = receiver(new_adapters[dev])

    if new.updated_at != nil and new.updated_at != old.updated_at and
         not quiet?(state.links[dev]),
       do: receiver_report(state, dev, new),
       else: state
  end

  defp quiet?(%{quiet_until: nil}), do: false
  defp quiet?(%{quiet_until: until}), do: System.monotonic_time(:millisecond) < until

  defp receiver_report(state, dev, report) do
    case state.links[dev] do
      nil ->
        state

      link ->
        if busy_step?(state, dev) do
          state
        else
          receiver = Map.merge(link.receiver, known(Map.take(report, @fields)))
          state = put_in(state.links[dev].receiver, receiver)
          sync_output(state, dev)
        end
    end
  end

  # Write the receiver's state to the output where it differs from what
  # the output shows, except fields with a request still to run.
  defp sync_output(state, dev) do
    link = state.links[dev]

    diff =
      for field <- @fields,
          not Map.has_key?(link.pending, field),
          value <- [link.receiver[field]],
          value != nil,
          value != link.shown[field],
          into: %{},
          do: {field, value}

    push(state, dev, diff)
  end

  defp push(state, _dev, diff) when diff == %{}, do: state

  defp push(state, dev, diff) do
    link = state.links[dev]

    # Not written means not shown: the next sync tries again.
    case safe(fn -> state.funs.update_config.(link.key, diff) end, {:error, :unavailable}) do
      :ok ->
        now = System.monotonic_time(:millisecond)

        # Only a running player echoes a write; a disabled output has none.
        echoes =
          if player_running?(state, link.key),
            do: for({field, value} <- diff, do: {field, value, now + state.echo_ttl_ms}),
            else: []

        # Pruned here too: with no player running, no event ever prunes.
        put_in(state.links[dev], %{
          link
          | shown: Map.merge(link.shown, diff),
            echoes: live_echoes(link.echoes, now) ++ echoes
        })

      error ->
        Logger.debug("CEC volume link: update #{inspect(link.key)}: #{inspect(error)}")
        state
    end
  end

  defp player_running?(state, key),
    do: state.outputs |> Map.get(key, %{}) |> Map.get(:enabled, true) == true

  defp take_echo(link, field, value) do
    echoes = live_echoes(link.echoes, System.monotonic_time(:millisecond))

    case Enum.split_while(echoes, &(not match?({^field, ^value, _}, &1))) do
      {before, [_echo | rest]} -> {:echo, %{link | echoes: before ++ rest}}
      {_all, []} -> {:none, %{link | echoes: echoes}}
    end
  end

  defp live_echoes(echoes, now), do: Enum.filter(echoes, fn {_f, _v, until} -> until > now end)

  # ── polling ───────────────────────────────────────────────────────────

  defp schedule_all(state, candidates) do
    {keep, drop} = Map.split(state.timers, Map.keys(candidates))
    Enum.each(drop, fn {_dev, {_token, timer}} -> Process.cancel_timer(timer) end)
    state = %{state | timers: keep}
    Enum.reduce(Map.keys(candidates), state, &schedule(&2, &1))
  end

  defp schedule(state, dev) do
    cond do
      Map.has_key?(state.busy, dev) or Map.has_key?(state.timers, dev) ->
        state

      not Map.has_key?(candidates(state), dev) ->
        state

      true ->
        delay =
          cond do
            Map.has_key?(state.links, dev) -> state.poll_ms
            Map.has_key?(state.power_at, dev) -> state.probe_ms
            true -> 0
          end

        token = make_ref()
        timer = Process.send_after(self(), {:poll, dev, token}, delay)
        %{state | timers: Map.put(state.timers, dev, {token, timer})}
    end
  end

  defp start_poll(state, dev) do
    linked? = Map.has_key?(state.links, dev)
    now = System.monotonic_time(:millisecond)

    check_power? =
      case Map.fetch(state.power_at, dev) do
        {:ok, at} -> not linked? or now - at >= state.probe_ms
        :error -> true
      end

    %{audio_status: audio_status, power_status: power_status} = state.funs

    task =
      Task.Supervisor.async_nolink(state.task_sup, fn ->
        power = if check_power?, do: power_status.(dev), else: :skipped
        audio = if linked? or power == {:ok, :on}, do: audio_status.(dev), else: :skipped
        {:poll, power, audio}
      end)

    put_job(state, dev, task, :poll)
  end

  defp put_job(state, dev, %Task{ref: ref, pid: pid}, kind) do
    job = %{ref: ref, pid: pid, kind: kind, gen: link_gen(state, dev)}
    %{state | busy: Map.put(state.busy, dev, job)}
  end

  defp link_gen(state, dev) do
    case state.links[dev] do
      %{gen: gen} -> gen
      nil -> nil
    end
  end

  defp busy_step?(state, dev), do: match?(%{kind: :step}, state.busy[dev])

  # ── job results ───────────────────────────────────────────────────────

  # A job started for an earlier link (or before this one) says nothing
  # about the current one.
  defp job_done(state, dev, %{gen: gen}, result) do
    if gen == link_gen(state, dev),
      do: job_done(state, dev, result),
      else: next(state, dev)
  end

  defp job_done(state, dev, {:poll, power, audio}) do
    state =
      if power == :skipped,
        do: state,
        else: put_in(state.power_at[dev], System.monotonic_time(:millisecond))

    outcome = poll_outcome([power, no_volume(audio)])

    state =
      case audio do
        {:ok, %{} = status} -> receiver_report(state, dev, status)
        _ -> state
      end

    state
    |> after_poll(dev, outcome, power, audio)
    |> next(dev)
  end

  defp job_done(state, dev, {:step, targets, status, error}) do
    if error, do: log_step_error(dev, targets, status, error)
    step_ended(state, dev, status, step_outcome(error, status))
  end

  defp job_done(state, dev, _crashed), do: step_ended(state, dev, nil, {:silent, :crashed})

  defp step_ended(state, dev, status, outcome) do
    case state.links[dev] do
      nil ->
        next(state, dev)

      link ->
        quiet_until = System.monotonic_time(:millisecond) + state.settle_ms
        receiver = Map.merge(link.receiver, known(status || %{}))

        step =
          case status do
            %{step: step} when is_integer(step) and step > 0 -> step
            _ -> link.step
          end

        link = %{link | receiver: receiver, quiet_until: quiet_until, step: step}
        state = put_in(state.links[dev], link)
        state |> count_outcome(dev, outcome) |> next(dev)
    end
  end

  # What a poll or run says about the receiver: `:answered`, `{:silent,
  # reason}` when the receiver didn't acknowledge or reply, or `:local` when
  # our own adapter couldn't ask (no logical address while it re-acquires
  # one after a hotplug, queue full, subsystem down), which says nothing
  # about the receiver and leaves the count alone.
  defp poll_outcome(results) do
    errors = for {:error, reason} <- results, do: reason

    case Enum.find(errors, &receiver_silent?/1) do
      nil -> if errors == [], do: :answered, else: :local
      reason -> {:silent, reason}
    end
  end

  # A stall or the press limit came with a readback, which has to carry a
  # volume (a mute-only run's may not). A run's only requests are audio
  # status reads, so a Feature Abort is a receiver refusing to report it.
  defp step_outcome(error, status) when error in [nil, :no_progress, :press_limit] do
    if match?(%{volume: volume} when is_integer(volume), status),
      do: :answered,
      else: {:silent, :unknown_volume}
  end

  defp step_outcome(:feature_abort, _status), do: {:silent, :unknown_volume}

  defp step_outcome(error, _status),
    do: if(receiver_silent?(error), do: {:silent, error}, else: :local)

  # `:timeout` is also what a request that got no reply returns. A
  # receiver that answers without a volume can't be followed either.
  defp receiver_silent?(reason),
    do: reason in [:nack, :timeout, :max_retries, :unknown_volume]

  defp no_volume({:ok, %{volume: nil}}), do: {:error, :unknown_volume}
  defp no_volume({:error, :feature_abort}), do: {:error, :unknown_volume}
  defp no_volume(audio), do: audio

  defp after_poll(state, dev, outcome, power, audio) do
    cond do
      Map.has_key?(state.links, dev) ->
        count_outcome(state, dev, outcome)

      MapSet.member?(state.lost, dev) and outcome == :answered and match?({:ok, :on}, power) ->
        found_again(state, dev, audio)

      true ->
        state
    end
  end

  defp count_outcome(state, dev, :answered), do: put_in(state.links[dev].failures, [])
  defp count_outcome(state, _dev, :local), do: state

  defp count_outcome(state, dev, {:silent, reason}) do
    failures = [reason | state.links[dev].failures]

    if length(failures) >= state.fail_unlink do
      reason = "receiver stopped answering: #{describe_failures(failures)}"

      # Software volume resumes at what the output shows: make that the
      # receiver's last known state, not a request it never reached.
      state = put_in(state.links[dev].pending, %{})
      state = sync_output(state, dev)
      %{unlink(state, dev, reason) | lost: MapSet.put(state.lost, dev)}
    else
      put_in(state.links[dev].failures, failures)
    end
  end

  # `[:timeout, :nack, :nack]` (newest first) -> ":nack ×2, :timeout ×1".
  defp describe_failures(failures) do
    failures
    |> Enum.reverse()
    |> Enum.chunk_by(& &1)
    |> Enum.map_join(", ", fn [reason | _] = run -> "#{inspect(reason)} ×#{length(run)}" end)
  end

  # A lost receiver answered a probe: relink from what it just said (the
  # record Cec.Server broadcasts may not have caught up yet).
  # Only for a device still a candidate: the probe may finish after its
  # adapter (or output) went away.
  defp found_again(state, dev, {:ok, %{volume: volume} = status}) when is_integer(volume) do
    if Map.has_key?(candidates(state), dev) do
      Logger.info("CEC volume link: receiver on #{dev} answers again")
      adapter = state.adapters[dev]
      merged = adapter |> receiver() |> Map.merge(known(status)) |> Map.put(:power, :on)
      adapters = Map.put(state.adapters, dev, Map.put(adapter, :receiver, merged))
      evaluate(%{state | lost: MapSet.delete(state.lost, dev), adapters: adapters})
    else
      state
    end
  end

  defp found_again(state, _dev, _audio), do: state

  # After any job: run what was requested meanwhile, else show the
  # receiver's state and go back to polling.
  defp next(state, dev) do
    case state.links[dev] do
      nil ->
        schedule(state, dev)

      _link ->
        if todo(state, dev) == %{} do
          state = put_in(state.links[dev].pending, %{})
          state |> sync_output(dev) |> schedule(dev)
        else
          start_step(state, dev)
        end
    end
  end

  defp log_step_error(dev, targets, status, error) do
    at = if status, do: " at #{inspect(known(status))}", else: ""

    Logger.info(
      "CEC volume link: #{dev} stopped short of #{inspect(targets)}#{at}: #{inspect(error)}"
    )
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp note_output(state, key, partial) do
    case Map.fetch(state.outputs, key) do
      {:ok, output} -> put_in(state.outputs[key], Map.merge(output, Map.delete(partial, :event)))
      :error -> state
    end
  end

  defp busy_job(state, ref) do
    Enum.find(state.busy, fn {_dev, job} -> job.ref == ref end)
  end

  defp by_dev(adapters), do: Map.new(adapters, &{&1.dev, &1})

  @unknown %{power: :unknown, volume: nil, muted: nil, updated_at: nil}

  defp receiver(%{receiver: receiver}) when is_map(receiver), do: Map.merge(@unknown, receiver)
  defp receiver(_adapter), do: @unknown

  defp known(status) do
    for {field, value} <- Map.take(status, @fields), value != nil, into: %{}, do: {field, value}
  end

  defp safe(fun, default) do
    fun.()
  catch
    :exit, _ -> default
  end
end
