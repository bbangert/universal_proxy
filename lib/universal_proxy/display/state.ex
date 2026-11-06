defmodule UniversalProxy.Display.State do
  @moduledoc """
  The TV UI's single writer: owns the `UniversalProxy.Display.Model`, feeds
  it every input, executes the effects it returns, and owns the viewport.

  ## With the UI on (`ui: true`)

  At start it subscribes to the HDMI output's display events
  (`"sendspin:display"`), the Sendspin state and output added/removed
  topics and `cec:events`, then binds to the output that carries the
  display roles and the CEC adapter on its HDMI link
  (`UniversalProxy.Display.Binding`), seeds from
  `UniversalProxy.Audio.display_snapshot/1` (events at or below the
  snapshot's `seq` are dropped), reads the persisted mode
  (`display_mode` in the output's `UniversalProxy.Audio.Store` config) and
  claims the adapter's remote keys (`UniversalProxy.Cec.claim_keys/2`).

  The viewport is started through the configured
  `UniversalProxy.Display.Renderer` when it is available and a DRM card
  exists (`<dri_dir>/card*`); otherwise the UI runs headless (mode, HA
  select and keys still work). A viewport that fails to start or crashes
  is retried with backoff, 1 s doubling to 5 min, reset once it has been
  up 60 s, and at once when the HDMI adapter's physical address becomes
  valid again (the TV is back). Screens come from
  `UniversalProxy.Display.View`.

  Controller commands, visualizer on/off and mode persistence are calls
  into the audio subsystem, which must never stall this loop: they run as
  `UniversalProxy.TaskSupervisor` tasks, one at a time in the order the
  model asked for them (a later "Off" must never be overtaken by an
  earlier "Visualizer"). The player pid is never cached.

  Events an effect produces (a snapshot's contents, a viewport that
  started) are handled after the rest of the current transition's
  effects, so they always build on its final state. Mode changes are broadcast on `UniversalProxy.Display.topic/0`
  as `{:display_mode, mode}`.

  The viewport reports the output size it got as `{:viewport_size,
  viewport, {w, h}}`; screens are laid out for that size (before the
  first report, for the configured `:preferred_size`).

  Timers fire as `{:display_timer, timer, gen}` messages (`timer` is
  `:idle`, `:retry` or `:stable`); a stale `gen` is ignored. While a
  viewport runs, a `{:display_clock, ref}` timer redraws the screen when
  it changes with time alone (`UniversalProxy.Display.View.next_refresh/2`:
  the progress bar, once a second while playing, and the burn-in drift
  every few minutes).

  ## MilkDrop

  With MilkDrop on (`UniversalProxy.MilkDrop.enabled?/0`, or the
  `:milkdrop` option) State also follows the preset pack
  (`UniversalProxy.MilkDrop.Pack`'s status and PubSub, `:ensure_pack` as a
  task; a restarted Pack's `{:milkdrop_pack_started, status}` replaces the
  cached status and lets the pack be asked for again) and runs the model's
  `{:yield, :milkdrop}` / `:reclaim` as a handover with the renderer's port
  owner, `UniversalProxy.Display.MilkDrop` (started unlinked and
  monitored):

    1. `:tapping` — the bound player's PCM tap is turned on, leased to this
       process (`UniversalProxy.Audio.pcm_tap/3`: the player turns it off
       if State dies), and its ring path read (`pcm_tap_status/1`), as an
       audio job like the others;
    2. `:preparing` — the renderer starts with the viewport's mode
       (`UniversalProxy.Display.OutputMode.renderer_mode/2`), the pack, the
       ring and the target's ladder, and builds GL without DRM master;
    3. on `prepared` the viewport is stopped (the model's `:yielded`) and
       `take` sent; `:taking` until `presenting`;
    4. `:presenting` — Left/Right/Select arrive as `next`/`prev` and
       `lock`/`unlock` casts;
    5. on reclaim, `release`; `:releasing` until `released`, then the
       viewport is started again at once and, once it runs, `exit`;
       `:exiting` until the renderer is gone. The PCM tap goes off again.

  Every phase is bounded (`:milkdrop_timeouts`, ms: tapping 10 000,
  preparing 20 000, taking 5 000, releasing 3 000, exiting 3 000). A
  timed-out step, a `take` the renderer reports failed, or a renderer that
  exits or crashes unasked (`{:milkdrop_exit, pid, status}`, `:wedged` and
  `:reaper_down` included) stops it (`UniversalProxy.Display.MilkDrop.stop/1`)
  and, if the viewport had yielded, starts the viewport again at once;
  the model counts the failure toward its crash latch, which is logged. A
  renderer that stopped because it overheated (`exiting` reason
  `thermal`) latches the bar visualizer. Nothing here waits on the
  renderer: commands are casts and its answers are messages.

  ## With the UI off (`ui: false`, the default)

  Nothing is subscribed or claimed and no viewport starts on its own: the
  viewport is started by hand (`UniversalProxy.Display.start_viewport/1`,
  `show/1`), as the renderer benchmarks do.

  ## Options

    * `:name` — registered name (default `#{inspect(__MODULE__)}`).
    * `:ui` — default: the configured value, else `false`.
    * `:renderer` — the renderer module (default: the configured one).
    * `:viewport_supervisor` — the `DynamicSupervisor` the viewport runs under.
    * `:dri_dir` — where DRM cards appear (default `"/dev/dri"`).
    * `:viewport_opts` — default `start/2` options for the renderer.
      Default: the configured `:layer_cache_mb`, `:preferred_size`,
      `:viz_tick_ms` and `:image_dirs`, and a `:viz_buffer` sized for the
      display roles' `:viz_offset_ms` and `:viz_rate`.
    * `:spec` — the first screen in manual mode (default: `Spec.now_playing/1`).
    * `:model_opts` — `UniversalProxy.Display.Model.new/1` options
      (default: the configured `:idle_ms`, `:party_idle_ms`, `:restart_ms`,
      `:restart_max_ms`, `:stable_ms`).
    * `:view_opts` — `UniversalProxy.Display.View.render/2` options.
    * `:pubsub`, `:task_supervisor` — default `UniversalProxy.PubSub`,
      `UniversalProxy.TaskSupervisor`.
    * `:audio`, `:cec` — maps of funs overriding the calls into the audio
      and CEC subsystems (tests).
    * `:milkdrop` — whether the MilkDrop mode is on (default
      `UniversalProxy.MilkDrop.enabled?/0`).
    * `:milkdrop_opts` — extra `UniversalProxy.Display.MilkDrop.start/1`
      options (`:binary`, `:ladder`, `:store`, `:task_supervisor`, ...).
    * `:milkdrop_timeouts` — per-phase timeouts (see "MilkDrop").
    * `:pack` — map of funs overriding `status`/`ensure` of
      `UniversalProxy.MilkDrop.Pack` (tests).
  """

  use GenServer

  require Logger

  alias UniversalProxy.{Audio, Cec, Display, MilkDrop}
  alias UniversalProxy.Display.{Binding, Mode, Model, OutputMode, Spec, View, Viz}

  @max_clock_ms 3_600_000

  @milkdrop_timeouts %{
    tapping: 10_000,
    preparing: 20_000,
    taking: 5_000,
    releasing: 3_000,
    exiting: 3_000
  }
  # Renderer errors that mean `take` failed (it stays prepared, not master).
  @take_errors ["master_timeout", "take_failed"]

  @model_keys [:idle_ms, :party_idle_ms, :restart_ms, :restart_max_ms, :stable_ms]
  @viewport_keys [:layer_cache_mb, :preferred_size, :viz_tick_ms, :image_dirs]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Whether `dri_dir` holds a DRM card node."
  @spec display_card?(Path.t()) :: boolean()
  def display_card?(dri_dir \\ "/dev/dri") do
    dri_dir |> Path.join("card*") |> Path.wildcard() |> Enum.any?()
  end

  # ── Init ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    config = Display.config()
    milkdrop? = Keyword.get_lazy(opts, :milkdrop, &MilkDrop.enabled?/0) == true

    state = %{
      ui: Keyword.get(opts, :ui, Keyword.get(config, :ui, false)),
      renderer:
        Keyword.get(opts, :renderer, Keyword.get(config, :renderer, Display.Renderer.Null)),
      supervisor:
        Keyword.get(opts, :viewport_supervisor, Display.Supervisor.viewport_supervisor()),
      dri_dir: Keyword.get(opts, :dri_dir, "/dev/dri"),
      viewport_opts:
        Keyword.get_lazy(opts, :viewport_opts, fn -> default_viewport_opts(config) end),
      view_opts: Keyword.get_lazy(opts, :view_opts, fn -> default_view_opts(config) end),
      spec: Keyword.get_lazy(opts, :spec, fn -> Spec.now_playing() end),
      viewport: nil,
      viz_tier: :full,
      model:
        Model.new(
          Keyword.put(
            Keyword.get_lazy(opts, :model_opts, fn -> Keyword.take(config, @model_keys) end),
            :milkdrop,
            milkdrop?
          )
        ),
      outputs: [],
      adapters: [],
      jobs: :queue.new(),
      job: nil,
      follow_ups: [],
      viz_on: nil,
      clock: nil,
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      task_sup: Keyword.get(opts, :task_supervisor, UniversalProxy.TaskSupervisor),
      audio: Map.merge(default_audio(), Map.new(Keyword.get(opts, :audio, %{}))),
      cec: Map.merge(default_cec(), Map.new(Keyword.get(opts, :cec, %{}))),
      milkdrop?: milkdrop?,
      md: nil,
      md_last: nil,
      md_opts: Keyword.get(opts, :milkdrop_opts, []),
      md_timeouts:
        Map.merge(@milkdrop_timeouts, Map.new(Keyword.get(opts, :milkdrop_timeouts, %{}))),
      pack: Map.merge(default_pack(), Map.new(Keyword.get(opts, :pack, %{})))
    }

    if state.ui do
      # Subscribe before seeding, so nothing published in between is lost
      # (the snapshot's seq drops what it already covers).
      for topic <-
            [
              "sendspin:display",
              "sendspin:state",
              "sendspin:output_added",
              "sendspin:output_removed",
              Cec.topic()
            ] ++ if(milkdrop?, do: [MilkDrop.pack_topic()], else: []),
          do: Phoenix.PubSub.subscribe(state.pubsub, topic)

      {:ok, state, {:continue, :start_ui}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:start_ui, state) do
    state = %{state | adapters: state.cec.list_adapters.(), outputs: state.audio.list_outputs.()}
    # The pack first, so a persisted MilkDrop mode sees it.
    state = if state.milkdrop?, do: dispatch(state, {:pack, state.pack.status.()}), else: state
    state = rebind(state)
    {:noreply, dispatch(state, {:display_available, display_available?(state)})}
  end

  # ── Calls ────────────────────────────────────────────────────────────

  @impl true
  def handle_call({:set_mode, mode}, _from, %{ui: true} = state),
    do: {:reply, :ok, dispatch(state, {:set_mode, mode})}

  def handle_call({:set_mode, _mode}, _from, state), do: {:reply, {:error, :disabled}, state}

  def handle_call(:mode, _from, %{ui: true} = state), do: {:reply, state.model.mode, state}
  def handle_call(:mode, _from, state), do: {:reply, nil, state}

  def handle_call({:start_viewport, _opts}, _from, %{ui: true} = state),
    do: {:reply, {:error, :ui_active}, state}

  def handle_call({:start_viewport, opts}, _from, state) do
    {reply, state} = state |> stop_viewport() |> start_viewport(opts)
    {:reply, reply, state}
  end

  def handle_call(:stop_viewport, _from, %{ui: true} = state), do: {:reply, :ok, state}
  def handle_call(:stop_viewport, _from, state), do: {:reply, :ok, stop_viewport(state)}

  def handle_call(:viewport, _from, state), do: {:reply, viewport_handle(state), state}

  def handle_call(:status, _from, state), do: {:reply, status(state), state}

  @impl true
  def handle_cast({:show, spec}, state) do
    if state.viewport, do: state.renderer.push(state.viewport.handle, spec)
    {:noreply, %{state | spec: spec}}
  end

  # ── Messages ─────────────────────────────────────────────────────────

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{viewport: %{ref: ref}} = state) do
    Logger.warning("[Display] viewport exited: #{inspect(reason)}")
    state = %{state | viewport: nil}

    if state.ui,
      do: {:noreply, dispatch(state, {:viewport, :down, reason})},
      else: {:noreply, state}
  end

  def handle_info({ref, _result}, %{job: ref} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, next_job(%{state | job: nil})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{job: ref} = state) do
    Logger.warning("[Display] audio call failed: #{inspect(reason)}")
    {:noreply, next_job(%{state | job: nil})}
  end

  def handle_info(_msg, %{ui: false} = state), do: {:noreply, state}

  def handle_info({:sendspin_display, key, seq, event}, state) do
    if bound?(state, key),
      do: {:noreply, dispatch(state, {:display_event, seq, event})},
      else: {:noreply, state}
  end

  def handle_info({:sendspin_state, key, event}, state) when is_map(event),
    do: {:noreply, sendspin_state(state, key, event)}

  def handle_info({:sendspin_output_added, _output}, state),
    do: {:noreply, state |> refresh_outputs() |> rebind()}

  def handle_info({:sendspin_output_removed, _output}, state),
    do: {:noreply, state |> refresh_outputs() |> rebind()}

  def handle_info({:cec_adapters, adapters}, state) when is_list(adapters),
    do: {:noreply, cec_adapters(state, adapters)}

  def handle_info({:cec_key, dev, key}, %{model: %{claimed: dev}} = state),
    do: {:noreply, dispatch(state, {:key, key})}

  def handle_info({:display_timer, timer, gen}, state),
    do: {:noreply, dispatch(state, {:timer, timer, gen})}

  def handle_info({:display_clock, ref}, %{clock: {ref, _due}} = state),
    do: {:noreply, arm_clock(run_effect(:render, %{state | clock: nil}))}

  def handle_info({:display_party, party}, state),
    do: {:noreply, dispatch(state, {:party, party})}

  def handle_info({:viewport_viz_tier, _pid, tier}, state),
    do: {:noreply, %{state | viz_tier: tier}}

  def handle_info({:viewport_size, handle, size}, %{viewport: %{handle: handle}} = state),
    do: {:noreply, dispatch(state, {:viewport_size, size})}

  def handle_info({:milkdrop_pack, status}, %{milkdrop?: true} = state),
    do: {:noreply, dispatch(state, {:pack, status})}

  def handle_info({:milkdrop_pack_started, status}, %{milkdrop?: true} = state),
    do: {:noreply, dispatch(state, {:pack_restarted, status})}

  # `ensure/0`'s own answer: only a final one (progress comes on PubSub,
  # and an unchanged error isn't broadcast).
  def handle_info({:milkdrop_pack_ensured, status}, %{milkdrop?: true} = state) do
    if match?({:error, _}, status) or match?({:ready, _, _}, status),
      do: {:noreply, dispatch(state, {:pack, status})},
      else: {:noreply, state}
  end

  def handle_info(
        {:milkdrop_ring, session, ring},
        %{md: %{session: session, phase: :tapping}} = state
      ),
      do: {:noreply, start_milkdrop(state, ring)}

  def handle_info({:milkdrop, pid, event}, %{md: %{pid: pid}} = state) when is_map(event),
    do: {:noreply, milkdrop_event(state, event)}

  def handle_info({:milkdrop_exit, pid, status}, %{md: %{pid: pid} = md} = state) do
    outcome =
      cond do
        md.exiting == "thermal" -> :thermal
        md.phase == :exiting -> :requested
        true -> {:crashed, md.exiting || status}
      end

    {:noreply, end_milkdrop(state, outcome)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{md: %{ref: ref} = md} = state) do
    outcome = if md.phase == :exiting, do: :requested, else: {:crashed, {:down, reason}}
    {:noreply, end_milkdrop(%{state | md: %{md | ref: nil, pid: nil}}, outcome)}
  end

  def handle_info(
        {:milkdrop_timeout, session, phase},
        %{md: %{session: session, phase: phase}} = state
      ),
      do: {:noreply, milkdrop_timeout(state, phase)}

  def handle_info(_msg, state), do: {:noreply, state}

  defp sendspin_state(state, key, %{event: "listening"}) do
    state = state |> refresh_outputs() |> rebind()
    if bound?(state, key), do: dispatch(state, {:player, :started}), else: state
  end

  defp sendspin_state(state, key, %{event: "shutdown"}) do
    if bound?(state, key), do: dispatch(state, {:player, :stopped}), else: state
  end

  defp sendspin_state(state, key, %{event: event}) do
    cond do
      not bound?(state, key) -> state
      event == "stream_start" -> dispatch(state, {:stream, :start})
      event in ["stream_end", "disconnected"] -> dispatch(state, {:stream, :end})
      true -> state
    end
  end

  defp sendspin_state(state, key, %{enabled: enabled?}) do
    stopped? = enabled? == false and bound?(state, key)
    state = if stopped?, do: dispatch(state, {:player, :stopped}), else: state
    state |> refresh_outputs() |> rebind()
  end

  defp sendspin_state(state, _key, _event), do: state

  defp cec_adapters(state, adapters) do
    old = bound_adapter(state)
    state = rebind(%{state | adapters: adapters})
    new = bound_adapter(state)

    # A Cec.Server restart drops the claim; claiming again is idempotent.
    if state.model.claimed && new, do: state.cec.claim_keys.(state.model.claimed, self())

    if new && Binding.valid_phys_addr?(new.phys_addr) &&
         not Binding.valid_phys_addr?(old && old.phys_addr) do
      state
      |> dispatch({:display_available, display_available?(state)})
      |> dispatch(:hdmi_link_up)
    else
      state
    end
  end

  defp tv_presence(state, %{tv_presence: presence}), do: dispatch(state, {:tv_presence, presence})
  defp tv_presence(state, _adapter), do: state

  # ── Model plumbing ───────────────────────────────────────────────────

  defp dispatch(state, event) do
    {model, effects} = Model.handle(state.model, event, now_ms())
    state = Enum.reduce(effects, %{state | model: model}, &run_effect/2)

    # Events the effects produced, after all of this transition's effects.
    {follow_ups, state} = Map.get_and_update(state, :follow_ups, &{&1, []})
    follow_ups |> Enum.reverse() |> Enum.reduce(state, &dispatch(&2, &1)) |> arm_clock()
  end

  # The screen also changes with time alone (the progress clock): one timer
  # redraws it when `View.next_refresh/2` says so. An earlier pending
  # wake-up is kept, so a stream of events can't keep pushing it out.
  defp arm_clock(%{viewport: nil} = state), do: cancel_clock(state)

  defp arm_clock(state) do
    now = now_ms()

    case View.next_refresh(state.model, view_opts(state, now)) do
      nil ->
        cancel_clock(state)

      ms ->
        # An early wake-up only redraws the same screen.
        ms = min(ms, @max_clock_ms)

        case state.clock do
          {_ref, due} when due <= now + ms ->
            state

          _other ->
            state = cancel_clock(state)
            ref = make_ref()
            Process.send_after(self(), {:display_clock, ref}, ms)
            %{state | clock: {ref, now + ms}}
        end
    end
  end

  defp cancel_clock(state), do: %{state | clock: nil}

  defp view_opts(state, now), do: Keyword.put(state.view_opts, :now, now)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp follow_up(state, event), do: %{state | follow_ups: [event | state.follow_ups]}

  defp run_effect(:render, state) do
    spec = View.render(state.model, view_opts(state, now_ms()))

    if state.viewport && spec != state.spec,
      do: state.renderer.push(state.viewport.handle, spec)

    %{state | spec: spec}
  end

  defp run_effect({:display, power}, state) do
    if state.viewport, do: state.renderer.set_display(state.viewport.handle, power)
    state
  end

  defp run_effect({:controller, command}, state) do
    with_key(state, fn key, audio ->
      fn ->
        case audio.controller.(key, command) do
          :ok -> :ok
          {:error, reason} -> Logger.info("[Display] #{command} not sent: #{inspect(reason)}")
        end
      end
    end)
  end

  defp run_effect({:push_mode, mode}, state) do
    Phoenix.PubSub.broadcast(state.pubsub, Display.topic(), {:display_mode, mode})
    state
  end

  defp run_effect({:persist_mode, mode}, state) do
    with_key(state, fn key, audio ->
      fn -> audio.update_config.(key, %{display_mode: Mode.to_option(mode)}) end
    end)
  end

  defp run_effect({:viz, viz}, state) do
    state = player_viz(state, viz != nil)

    if state.viewport do
      state.renderer.set_viz(state.viewport.handle, viz_source(state, viz))
    end

    %{state | viz_tier: :full}
  end

  defp run_effect({:claim_keys, dev}, state) do
    state.cec.claim_keys.(dev, self())
    state
  end

  defp run_effect({:release_keys, dev}, state) do
    state.cec.release_keys.(dev)
    state
  end

  defp run_effect({:snapshot, key}, state) do
    if bound?(state, key) do
      {seq, snapshot} = state.audio.display_snapshot.(key)
      follow_up(state, {:snapshot, seq, snapshot})
    else
      state
    end
  end

  defp run_effect({:start_viewport, rung}, state) do
    spec = View.render(state.model, view_opts(state, now_ms()))

    case start_viewport(%{state | spec: spec}, Keyword.put(rung, :owner, self())) do
      {{:ok, _handle}, state} ->
        follow_up(state, {:viewport, :started})

      {{:error, reason}, state} ->
        Logger.warning("[Display] viewport did not start: #{inspect(reason)}")
        follow_up(state, {:viewport, :start_failed, reason})
    end
  end

  defp run_effect(:stop_viewport, state), do: stop_viewport(state)

  defp run_effect({:yield, :milkdrop}, state), do: yield_milkdrop(state)

  defp run_effect(:reclaim, state), do: reclaim_milkdrop(state)

  defp run_effect({:milkdrop_cmd, cmd}, state), do: milkdrop_cmd(state, cmd)

  defp run_effect(:ensure_pack, state) do
    server = self()
    ensure = state.pack.ensure

    case Task.Supervisor.start_child(state.task_sup, fn ->
           send(server, {:milkdrop_pack_ensured, ensure.()})
         end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        Logger.warning("[Display] MilkDrop pack not asked for: #{inspect(reason)}")
    end

    state
  catch
    :exit, reason ->
      Logger.warning("[Display] MilkDrop pack not asked for: #{inspect(reason)}")
      state
  end

  defp run_effect({:schedule, timer, gen, ms}, state) do
    Process.send_after(self(), {:display_timer, timer, gen}, ms)
    state
  end

  defp viz_source(%{model: %{binding: %{key: key, client_id: id}}} = state, viz)
       when is_binary(id) and viz in [:strip, :full],
       do: %{topic: state.audio.viz_topic.(id), key: key, mode: viz}

  defp viz_source(_state, _viz), do: nil

  # Visualizer frames on (the bound output's player) or off. `viz_on` is the
  # output last turned on, so after the binding moved, "off" still reaches
  # the player that is actually emitting frames.
  defp player_viz(state, on?) do
    bound = state.model.binding && state.model.binding.key
    old = state.viz_on

    state =
      if old && (not on? or old != bound),
        do: enqueue(state, viz_job(state.audio, old, false)),
        else: state

    if on? && bound,
      do: %{enqueue(state, viz_job(state.audio, bound, true)) | viz_on: bound},
      else: %{state | viz_on: nil}
  end

  defp viz_job(audio, key, on?), do: fn -> audio.viz_enable.(key, on?) end

  # Queues the job `build.(key, audio)` returns, when bound.
  defp with_key(state, build) do
    case state.model.binding do
      %{key: key} -> enqueue(state, build.(key, state.audio))
      nil -> state
    end
  end

  defp enqueue(state, fun), do: next_job(%{state | jobs: :queue.in(fun, state.jobs)})

  # Starts the next queued audio job unless one is running. One at a time,
  # so the audio subsystem sees them in order.
  defp next_job(%{job: nil} = state) do
    case :queue.out(state.jobs) do
      {{:value, fun}, jobs} ->
        state = %{state | jobs: jobs}

        try do
          %{state | job: Task.Supervisor.async_nolink(state.task_sup, fun).ref}
        catch
          :exit, reason ->
            Logger.warning("[Display] audio call not started: #{inspect(reason)}")
            next_job(state)
        end

      {:empty, _jobs} ->
        state
    end
  end

  defp next_job(state), do: state

  # ── MilkDrop handover ────────────────────────────────────────────────

  # Step 1: the PCM tap on and its ring path, as an audio job (ordered
  # after the previous session's tap off).
  defp yield_milkdrop(
         %{md: nil, model: %{binding: %{key: key}, pack: {:ready, version, dir}}} = state
       ) do
    session = make_ref()
    server = self()
    audio = state.audio

    state =
      enqueue(state, fn ->
        pcm_tap(audio, key, true, server)
        send(server, {:milkdrop_ring, session, ring_path(audio, key)})
      end)

    md = %{
      session: session,
      phase: :tapping,
      timer: nil,
      pid: nil,
      ref: nil,
      tap_key: key,
      version: version,
      dir: dir,
      ring: nil,
      exiting: nil,
      preset: nil,
      locked: false,
      stats: nil
    }

    milkdrop_phase(%{state | md: md}, :tapping)
  end

  # The model yields only with both, and never while a session is still
  # ending; should that ever not hold, the running session is left alone.
  defp yield_milkdrop(%{md: nil} = state) do
    Logger.warning("[Display] MilkDrop: no pack or player to yield to")
    follow_up(state, {:milkdrop, :ended, {:crashed, :not_ready}})
  end

  defp yield_milkdrop(state) do
    Logger.warning("[Display] MilkDrop: a session is still running; not yielding again")
    state
  end

  # Step 2: the renderer, building GL off-screen while the viewport shows.
  defp start_milkdrop(%{md: md} = state, ring) do
    size = state.model.size || Keyword.get(state.view_opts, :size) || {1280, 720}

    opts =
      Keyword.merge(state.md_opts,
        owner: self(),
        mode: OutputMode.renderer_mode(size),
        pack_dir: md.dir,
        pack_version: md.version,
        ring_path: ring
      )

    case Display.MilkDrop.start(opts) do
      {:ok, pid} ->
        md = %{md | pid: pid, ref: Process.monitor(pid), ring: ring}
        milkdrop_phase(%{state | md: md}, :preparing)

      {:error, reason} ->
        Logger.warning("[Display] MilkDrop renderer did not start: #{inspect(reason)}")
        end_milkdrop(state, {:crashed, {:start_failed, reason}})
    end
  end

  # Step 3: the viewport stops, the renderer takes the display.
  defp milkdrop_event(%{md: %{phase: :preparing, session: session}} = state, %{event: :prepared}) do
    state = state |> stop_viewport() |> dispatch({:milkdrop, :yielded})

    case state.md do
      %{session: ^session, phase: :preparing, pid: pid} ->
        :ok = Display.MilkDrop.take(pid)
        milkdrop_phase(state, :taking)

      _other ->
        state
    end
  end

  defp milkdrop_event(%{md: %{phase: :taking}} = state, %{event: :presenting} = event) do
    Logger.info(
      "[Display] MilkDrop presenting (modeset: #{inspect(event[:modeset])}, master in #{inspect(event[:master_ms])} ms)"
    )

    state |> milkdrop_phase(:presenting) |> dispatch({:milkdrop, :presenting})
  end

  # Step 5: the viewport takes the display back, then the renderer exits.
  defp milkdrop_event(%{md: %{phase: :releasing, session: session}} = state, %{event: :released}) do
    state = dispatch(state, {:milkdrop, :released})

    case state.md do
      %{session: ^session, phase: :releasing, pid: pid} ->
        :ok = Display.MilkDrop.exit(pid)
        milkdrop_phase(state, :exiting)

      _other ->
        state
    end
  end

  defp milkdrop_event(%{md: %{phase: :taking}} = state, %{event: :error, reason: reason})
       when reason in @take_errors,
       do: abort_milkdrop(state, {:take_failed, reason})

  defp milkdrop_event(%{md: md} = state, %{event: :preset} = event) do
    locked = if is_boolean(event[:locked]), do: event.locked, else: md.locked
    %{state | md: %{md | preset: event[:file], locked: locked}}
  end

  defp milkdrop_event(%{md: md} = state, %{event: :stats} = event),
    do: %{state | md: %{md | stats: Map.delete(event, :event)}}

  defp milkdrop_event(%{md: md} = state, %{event: :exiting} = event),
    do: %{state | md: %{md | exiting: event[:reason]}}

  defp milkdrop_event(state, %{event: :error} = event) do
    Logger.info("[Display] MilkDrop renderer error: #{inspect(Map.delete(event, :event))}")
    state
  end

  defp milkdrop_event(state, %{event: :skip} = event) do
    Logger.info(
      "[Display] MilkDrop skipped #{inspect(event[:preset])}: #{inspect(event[:reason])}"
    )

    state
  end

  defp milkdrop_event(state, _event), do: state

  defp reclaim_milkdrop(%{md: %{phase: :tapping} = md} = state) do
    state = %{
      cancel_milkdrop_timer(state)
      | md: nil,
        md_last: %{outcome: :requested, phase: md.phase}
    }

    state |> pcm_tap_off(md.tap_key) |> follow_up({:milkdrop, :ended, :requested})
  end

  defp reclaim_milkdrop(%{md: %{phase: :preparing, pid: pid}} = state) do
    :ok = Display.MilkDrop.exit(pid)
    milkdrop_phase(state, :exiting)
  end

  defp reclaim_milkdrop(%{md: %{phase: phase, pid: pid}} = state)
       when phase in [:taking, :presenting] do
    :ok = Display.MilkDrop.release(pid)
    milkdrop_phase(state, :releasing)
  end

  defp reclaim_milkdrop(state), do: state

  defp milkdrop_cmd(%{md: %{phase: phase, pid: pid} = md} = state, cmd)
       when phase in [:preparing, :taking, :presenting] and is_pid(pid) do
    case cmd do
      :next ->
        Display.MilkDrop.next(pid)
        state

      :prev ->
        Display.MilkDrop.prev(pid)
        state

      :toggle_lock ->
        # Flipped at once so a quick second press toggles back; the next
        # `preset` event has the renderer's word.
        if md.locked, do: Display.MilkDrop.unlock(pid), else: Display.MilkDrop.lock(pid)
        %{state | md: %{md | locked: not md.locked}}
    end
  end

  defp milkdrop_cmd(state, _cmd), do: state

  defp milkdrop_timeout(state, :tapping) do
    Logger.warning("[Display] MilkDrop: no PCM tap ring in time; the visuals get silence")
    start_milkdrop(state, nil)
  end

  defp milkdrop_timeout(state, :exiting) do
    Logger.warning("[Display] MilkDrop renderer did not exit in time; stopping it")
    :ok = Display.MilkDrop.stop(state.md.pid)
    end_milkdrop(state, :requested)
  end

  defp milkdrop_timeout(state, phase), do: abort_milkdrop(state, {:timeout, phase})

  defp abort_milkdrop(%{md: md} = state, why) do
    Logger.warning("[Display] MilkDrop handover failed (#{inspect(why)}); stopping the renderer")
    if md.pid, do: :ok = Display.MilkDrop.stop(md.pid)
    end_milkdrop(state, {:crashed, why})
  end

  # The session is over (the renderer gone or stopped): tap off, and the
  # model restarts the viewport if it had yielded.
  defp end_milkdrop(%{md: md} = state, outcome) do
    state = cancel_milkdrop_timer(state)
    if md.ref, do: Process.demonitor(md.ref, [:flush])

    case outcome do
      :requested ->
        :ok

      other ->
        Logger.warning("[Display] MilkDrop renderer ended in #{md.phase}: #{inspect(other)}")
    end

    latch = state.model.milkdrop.latch

    state =
      %{state | md: nil, md_last: %{outcome: outcome, phase: md.phase}}
      |> pcm_tap_off(md.tap_key)
      |> dispatch({:milkdrop, :ended, outcome})

    log_latch(latch, state.model.milkdrop, outcome)
    state
  end

  defp log_latch(nil, %{latch: :crashed, crashes: crashes}, outcome) do
    Logger.warning(
      "[Display] MilkDrop off until the mode is chosen again: #{length(crashes)} renderer failures in 10 min (last: #{inspect(outcome)})"
    )
  end

  defp log_latch(nil, %{latch: :thermal}, _outcome) do
    Logger.warning(
      "[Display] MilkDrop off until the mode is chosen again: the renderer stopped to cool down"
    )
  end

  defp log_latch(_before, _milkdrop, _outcome), do: :ok

  # Every phase but `:presenting` is bounded.
  defp milkdrop_phase(state, phase) do
    %{md: md} = state = cancel_milkdrop_timer(state)

    timer =
      case Map.get(state.md_timeouts, phase) do
        nil -> nil
        ms -> Process.send_after(self(), {:milkdrop_timeout, md.session, phase}, ms)
      end

    %{state | md: %{md | phase: phase, timer: timer}}
  end

  defp cancel_milkdrop_timer(%{md: %{timer: timer} = md} = state) when is_reference(timer) do
    Process.cancel_timer(timer)
    %{state | md: %{md | timer: nil}}
  end

  defp cancel_milkdrop_timer(state), do: state

  defp pcm_tap_off(state, key) do
    audio = state.audio
    server = self()
    enqueue(state, fn -> pcm_tap(audio, key, false, server) end)
  end

  defp pcm_tap(audio, key, on?, owner) do
    case audio.pcm_tap.(key, on?, owner) do
      :ok -> :ok
      {:error, reason} -> Logger.info("[Display] PCM tap #{on?} not set: #{inspect(reason)}")
    end
  end

  defp ring_path(audio, key) do
    case audio.pcm_tap_status.(key) do
      {:ok, %{path: path}} when is_binary(path) -> path
      _other -> nil
    end
  end

  # ── Binding ──────────────────────────────────────────────────────────

  # Also (re)applies the bound adapter's cached TV presence: a new binding
  # starts from :unknown in the model.
  defp rebind(state) do
    binding = Binding.resolve(state.outputs, state.adapters)

    state =
      dispatch(state, {:bound, binding, persisted_mode(state.outputs, binding, state.milkdrop?)})

    tv_presence(state, bound_adapter(state))
  end

  defp refresh_outputs(state), do: %{state | outputs: state.audio.list_outputs.()}

  defp persisted_mode(_outputs, nil, _milkdrop?), do: nil

  defp persisted_mode(outputs, %{key: key}, milkdrop?) do
    with %{display_mode: option} <- Enum.find(outputs, &(Map.get(&1, :key) == key)),
         {:ok, mode} <- Mode.parse(option, milkdrop?) do
      mode
    else
      _ -> nil
    end
  end

  defp bound?(state, key), do: match?(%{key: ^key}, state.model.binding)

  defp bound_adapter(%{model: %{binding: %{cec_dev: dev}}} = state) when is_binary(dev),
    do: Enum.find(state.adapters, &(Map.get(&1, :dev) == dev))

  defp bound_adapter(_state), do: nil

  defp display_available?(state),
    do: state.renderer.available?() and display_card?(state.dri_dir)

  # ── Viewport ─────────────────────────────────────────────────────────

  defp start_viewport(state, opts) do
    opts = state.viewport_opts |> Keyword.merge(opts) |> Keyword.put_new(:spec, state.spec)

    case state.renderer.start(state.supervisor, opts) do
      {:ok, handle} ->
        ref = if is_pid(handle), do: Process.monitor(handle)
        {{:ok, handle}, %{state | viewport: %{handle: handle, ref: ref}}}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp stop_viewport(%{viewport: nil} = state), do: state

  defp stop_viewport(%{viewport: %{handle: handle, ref: ref}} = state) do
    if ref, do: Process.demonitor(ref, [:flush])
    :ok = state.renderer.stop(handle)
    %{state | viewport: nil}
  end

  defp viewport_handle(%{viewport: nil}), do: nil
  defp viewport_handle(%{viewport: %{handle: handle}}), do: handle

  # ── Status ───────────────────────────────────────────────────────────

  defp status(state) do
    base = %{
      running: true,
      ui: state.ui,
      renderer: state.renderer,
      available: state.renderer.available?(),
      display_card: display_card?(state.dri_dir),
      viewport: viewport_handle(state)
    }

    if state.ui do
      m = state.model

      Map.merge(base, %{
        mode: m.mode,
        screen: Model.screen(m),
        playback: m.playback,
        blanked: m.blanked,
        party: m.party,
        focus: m.focus,
        tv_presence: m.tv_presence,
        binding: m.binding,
        keys_claimed: m.claimed,
        viz: m.viz,
        viz_tier: state.viz_tier,
        size: m.size,
        lifecycle: m.viewport
      })
      |> Map.merge(if state.milkdrop?, do: %{milkdrop: milkdrop_status(state)}, else: %{})
    else
      base
    end
  end

  defp milkdrop_status(%{model: m, md: md} = state) do
    session =
      if md do
        %{
          phase: md.phase,
          renderer: md.pid,
          ring: md.ring,
          pack_version: md.version,
          preset: md.preset,
          locked: md.locked,
          stats: md.stats
        }
      else
        %{phase: nil}
      end

    Map.merge(session, %{
      pack: m.pack,
      yield: m.milkdrop.yield,
      latch: m.milkdrop.latch,
      failures: length(m.milkdrop.crashes),
      last: state.md_last
    })
  end

  # ── Defaults ─────────────────────────────────────────────────────────

  # The visualizer buffer holds one lead time of frames at the player's rate.
  defp default_viewport_opts(config) do
    roles = Audio.DisplayRoles.config()

    config
    |> Keyword.take(@viewport_keys)
    |> drop_nil()
    |> Keyword.put_new(
      :viz_buffer,
      Viz.buffer_cap(roles[:viz_offset_ms], roles[:viz_rate])
    )
  end

  defp default_view_opts(config) do
    [
      size: Keyword.get(config, :preferred_size),
      bars: Keyword.get(Audio.DisplayRoles.config(), :viz_bins)
    ]
  end

  defp default_audio do
    %{
      list_outputs: &list_outputs/0,
      display_snapshot: &Audio.display_snapshot/1,
      controller: &Audio.controller/2,
      viz_enable: &Audio.viz_enable/2,
      viz_topic: &Audio.viz_topic/1,
      update_config: &update_config/2,
      pcm_tap: &Audio.pcm_tap/3,
      pcm_tap_status: &Audio.pcm_tap_status/1
    }
  end

  defp default_pack do
    %{status: fn -> MilkDrop.Pack.status() end, ensure: fn -> MilkDrop.Pack.ensure() end}
  end

  defp default_cec do
    %{
      list_adapters: &Cec.list_adapters/0,
      claim_keys: &Cec.claim_keys/2,
      release_keys: &Cec.release_keys/1
    }
  end

  defp list_outputs do
    Audio.list_outputs()
  catch
    :exit, _ -> []
  end

  defp update_config(key, params) do
    case Audio.update_config(key, params) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[Display] mode not persisted: #{inspect(reason)}")
    end
  catch
    :exit, reason -> Logger.warning("[Display] mode not persisted: #{inspect(reason)}")
  end

  defp drop_nil(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)
end
