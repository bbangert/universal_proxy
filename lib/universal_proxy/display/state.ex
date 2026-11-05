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

  Timers fire as `{:display_timer, timer, gen}` messages (`timer` is
  `:idle`, `:retry` or `:stable`); a stale `gen` is ignored.

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
      `:viz_tick_ms` and `:image_dirs`.
    * `:spec` — the first screen in manual mode (default: `Spec.now_playing/1`).
    * `:model_opts` — `UniversalProxy.Display.Model.new/1` options
      (default: the configured `:idle_ms`, `:party_idle_ms`, `:restart_ms`,
      `:restart_max_ms`, `:stable_ms`).
    * `:view_opts` — `UniversalProxy.Display.View.render/2` options.
    * `:pubsub`, `:task_supervisor` — default `UniversalProxy.PubSub`,
      `UniversalProxy.TaskSupervisor`.
    * `:audio`, `:cec` — maps of funs overriding the calls into the audio
      and CEC subsystems (tests).
  """

  use GenServer

  require Logger

  alias UniversalProxy.{Audio, Cec, Display}
  alias UniversalProxy.Display.{Binding, Mode, Model, Spec, View}

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

    state = %{
      ui: Keyword.get(opts, :ui, Keyword.get(config, :ui, false)),
      renderer:
        Keyword.get(opts, :renderer, Keyword.get(config, :renderer, Display.Renderer.Null)),
      supervisor:
        Keyword.get(opts, :viewport_supervisor, Display.Supervisor.viewport_supervisor()),
      dri_dir: Keyword.get(opts, :dri_dir, "/dev/dri"),
      viewport_opts:
        Keyword.get_lazy(opts, :viewport_opts, fn ->
          config |> Keyword.take(@viewport_keys) |> drop_nil()
        end),
      view_opts: Keyword.get_lazy(opts, :view_opts, fn -> default_view_opts(config) end),
      spec: Keyword.get_lazy(opts, :spec, fn -> Spec.now_playing() end),
      viewport: nil,
      viz_tier: :full,
      model:
        Model.new(
          Keyword.get_lazy(opts, :model_opts, fn -> Keyword.take(config, @model_keys) end)
        ),
      outputs: [],
      adapters: [],
      jobs: :queue.new(),
      job: nil,
      follow_ups: [],
      viz_on: nil,
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      task_sup: Keyword.get(opts, :task_supervisor, UniversalProxy.TaskSupervisor),
      audio: Map.merge(default_audio(), Map.new(Keyword.get(opts, :audio, %{}))),
      cec: Map.merge(default_cec(), Map.new(Keyword.get(opts, :cec, %{})))
    }

    if state.ui do
      # Subscribe before seeding, so nothing published in between is lost
      # (the snapshot's seq drops what it already covers).
      for topic <- [
            "sendspin:display",
            "sendspin:state",
            "sendspin:output_added",
            "sendspin:output_removed",
            Cec.topic()
          ],
          do: Phoenix.PubSub.subscribe(state.pubsub, topic)

      {:ok, state, {:continue, :start_ui}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:start_ui, state) do
    state = %{state | adapters: state.cec.list_adapters.(), outputs: state.audio.list_outputs.()}
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

  def handle_info({:display_party, party}, state),
    do: {:noreply, dispatch(state, {:party, party})}

  def handle_info({:viewport_viz_tier, _pid, tier}, state),
    do: {:noreply, %{state | viz_tier: tier}}

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
    {model, effects} = Model.handle(state.model, event, System.monotonic_time(:millisecond))
    state = Enum.reduce(effects, %{state | model: model}, &run_effect/2)

    # Events the effects produced, after all of this transition's effects.
    {follow_ups, state} = Map.get_and_update(state, :follow_ups, &{&1, []})
    follow_ups |> Enum.reverse() |> Enum.reduce(state, &dispatch(&2, &1))
  end

  defp follow_up(state, event), do: %{state | follow_ups: [event | state.follow_ups]}

  defp run_effect(:render, state) do
    spec = View.render(state.model, state.view_opts)

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
    spec = View.render(state.model, state.view_opts)

    case start_viewport(%{state | spec: spec}, Keyword.put(rung, :owner, self())) do
      {{:ok, _handle}, state} ->
        follow_up(state, {:viewport, :started})

      {{:error, reason}, state} ->
        Logger.warning("[Display] viewport did not start: #{inspect(reason)}")
        follow_up(state, {:viewport, :start_failed, reason})
    end
  end

  defp run_effect(:stop_viewport, state), do: stop_viewport(state)

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

  # ── Binding ──────────────────────────────────────────────────────────

  # Also (re)applies the bound adapter's cached TV presence: a new binding
  # starts from :unknown in the model.
  defp rebind(state) do
    binding = Binding.resolve(state.outputs, state.adapters)
    state = dispatch(state, {:bound, binding, persisted_mode(state.outputs, binding)})
    tv_presence(state, bound_adapter(state))
  end

  defp refresh_outputs(state), do: %{state | outputs: state.audio.list_outputs.()}

  defp persisted_mode(_outputs, nil), do: nil

  defp persisted_mode(outputs, %{key: key}) do
    with %{display_mode: option} <- Enum.find(outputs, &(Map.get(&1, :key) == key)),
         {:ok, mode} <- Mode.parse(option) do
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
        lifecycle: m.viewport
      })
    else
      base
    end
  end

  # ── Defaults ─────────────────────────────────────────────────────────

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
      update_config: &update_config/2
    }
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
