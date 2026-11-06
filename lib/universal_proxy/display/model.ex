defmodule UniversalProxy.Display.Model do
  @moduledoc """
  The TV UI's state machine, as a pure reducer:
  `handle(model, event, now_ms) :: {model, [effect]}`.

  `UniversalProxy.Display.State` feeds it every input (display-role events
  from the HDMI output's player, remote keys, Home Assistant mode changes,
  CEC TV presence, party state, timers and viewport lifecycle) and executes
  the effects it returns. Nothing here touches a process, so every rule is
  testable as a list of events.

  ## Screen priority (P5)

  `screen/1`, first match wins:

    1. mode Off, or blanked → `:blank`
    2. mode Party QR → `:party_qr` (or `:party_off` while no party is on)
    3. yielded to the MilkDrop renderer → `:milkdrop`
    4. playing → the mode's view, with the party QR overlay while a party
       is on (unless Exit hid it)
    5. a party is on → `:party_qr` as the idle screen
    6. otherwise → the mode's view (paused / idle)

  The MilkDrop mode's view is `{:milkdrop_preparing, pct}`,
  `:milkdrop_error` or `{:visualizer, overlay?}` (see "MilkDrop").

  ## Idle blanking (D3)

  While nothing plays, a generation-tagged idle timer runs (`idle_ms`, or
  `party_idle_ms` while the party QR is the screen); when it fires the
  screen blanks to a black frame, keeping the display mode on. Playback
  starting, a party turning on, a remote key (the waking key is consumed)
  and a Home Assistant mode change other than Off wake it. Explicit Off
  beats all of them.

  ## Remote keys (P4)

  Left/Right move focus across `[:prev, :play_pause, :next]`, Up/Down cycle
  Now Playing ↔ Visualizer (↔ MilkDrop) ↔ Party QR, Select activates the focused
  control, Play/Pause/Stop/Forward/Backward act directly, Exit hides the
  party overlay or else returns to Now Playing.

  ## MilkDrop (`:milkdrop` mode, only with the `:milkdrop` option)

  The MilkDrop renderer draws the screen itself, so the viewport yields
  the display to it (no compositing). While the HDMI output's player is
  playing and the preset pack is `{:ready, version, dir}` (`{:pack,
  status}` events, `UniversalProxy.MilkDrop.Pack`), the model emits
  `{:yield, :milkdrop}`; when any of that stops holding (a pause, another
  mode, the player gone) it emits `:reclaim`. The owner reports the
  handover back: `{:milkdrop, :yielded}` once the viewport is stopped
  (status `:yielded`: no retry, link-up or display-available restarts),
  `{:milkdrop, :released}` once the renderer dropped the display (the
  viewport is started again at once), and `{:milkdrop, :ended, outcome}`
  once the renderer is gone (`:requested`, `:thermal` or `{:crashed,
  why}`; the viewport is started again if it was still yielded). A new
  yield waits until the previous session ended, and needs the viewport's
  connector (`viewport_connector/1`, from the bound output's HDMI port):
  without one the mode shows the bars, since the renderer could present on
  another TV. `{:pack_restarted, status}` (a new Pack process) replaces the
  pack status and lets a missing pack be asked for again.

  Otherwise the mode shows the bar visualizer, or while the pack is
  missing (`:ensure_pack` asks for it) or downloading a "Preparing
  visualizer… N%" screen, and after a pack error a short error notice
  (`milkdrop_notice_ms`). A thermal exit, or `milkdrop_crash_limit`
  failures within `milkdrop_crash_window_ms`, latch MilkDrop off (the bar
  visualizer instead) until the next explicit mode change; a single
  failure only holds the next yield back for `milkdrop_retry_ms`. While
  the renderer is wanted, Left/Right/Select are `{:milkdrop_cmd, :prev |
  :next | :toggle_lock}`, and no party overlay shows (P6).

  ## Viewport lifecycle

  The model also tracks the renderer: start when a display is available,
  back off 1 s → 5 min on start errors and crashes (reset after
  `stable_ms` up), retry at once when the HDMI link comes back, and step
  down the renderer `ladder` after `crash_limit` identical crashes. The
  output size the viewport reports (`{:viewport_size, {w, h}}`, the mode
  it chose) is kept in `size`, which the view scales its layout to.
  """

  alias UniversalProxy.Display.{Mode, Progress}

  @focus_order [:prev, :play_pause, :next]

  @defaults %{
    idle_ms: 120_000,
    party_idle_ms: 600_000,
    restart_ms: 1_000,
    restart_max_ms: 300_000,
    stable_ms: 60_000,
    crash_limit: 3,
    ladder: [[api: :auto], [api: :raster, mode: {1280, 720}]],
    milkdrop: false,
    milkdrop_crash_limit: 3,
    milkdrop_crash_window_ms: 600_000,
    milkdrop_retry_ms: 5_000,
    milkdrop_notice_ms: 5_000
  }

  @type playback :: :playing | :paused | :stopped
  @type party :: :off | %{required(:url) => String.t(), optional(atom()) => term()}
  @type focus :: :prev | :play_pause | :next
  @type tv_presence :: :present | :absent | :unknown
  @type viz :: :strip | :full | nil
  @type screen ::
          :blank
          | :party_qr
          | :party_off
          | :milkdrop
          | :milkdrop_error
          | {:milkdrop_preparing, 0..100 | nil}
          | {:now_playing | :visualizer, overlay :: boolean()}
  @type key :: atom()
  @type binding :: %{
          required(:key) => UniversalProxy.Audio.key(),
          required(:client_id) => String.t() | nil,
          required(:cec_dev) => String.t() | nil,
          optional(:hdmi_port) => non_neg_integer() | nil
        }
  @type timer :: :idle | :retry | :stable | :milkdrop_retry | :milkdrop_notice
  @type size :: {pos_integer(), pos_integer()}

  @type vp_status ::
          :idle | :headless | :starting | :running | :backoff | :failed | :yielded
  @type viewport :: %{
          status: vp_status(),
          gen: non_neg_integer(),
          rung: non_neg_integer(),
          crashes: non_neg_integer(),
          crash_key: term(),
          delay_ms: pos_integer() | nil,
          reason: term(),
          port: non_neg_integer() | nil
        }

  @type pack :: UniversalProxy.MilkDrop.Pack.status() | nil
  @type milkdrop_outcome :: :requested | :thermal | {:crashed, term()}
  @type milkdrop_cmd :: :next | :prev | :toggle_lock
  @type milkdrop :: %{
          yield: boolean(),
          active: boolean(),
          latch: :thermal | :crashed | nil,
          crashes: [integer()],
          hold: non_neg_integer() | nil,
          notice: non_neg_integer() | nil,
          ensure: boolean(),
          gen: non_neg_integer()
        }

  @type event ::
          {:bound, binding() | nil, Mode.t() | nil}
          | {:snapshot, non_neg_integer(), map()}
          | {:display_event, non_neg_integer(), map()}
          | {:player, :started | :stopped}
          | {:stream, :start | :end}
          | {:key, key()}
          | {:set_mode, Mode.t()}
          | {:party, party()}
          | {:tv_presence, tv_presence()}
          | {:timer, timer(), non_neg_integer()}
          | {:display_available, boolean()}
          | {:viewport, :started}
          | {:viewport, :start_failed | :down, term()}
          | {:viewport_size, size()}
          | :hdmi_link_up
          | {:pack, pack()}
          | {:pack_restarted, pack()}
          | {:milkdrop, :yielded | :presenting | :released}
          | {:milkdrop, :ended, milkdrop_outcome()}

  @type effect ::
          :render
          | {:display, :on | :off}
          | {:controller, UniversalProxy.Audio.Player.controller_command()}
          | {:push_mode, Mode.t()}
          | {:persist_mode, Mode.t()}
          | {:viz, viz()}
          | {:claim_keys, String.t()}
          | {:release_keys, String.t()}
          | {:snapshot, UniversalProxy.Audio.key()}
          | {:start_viewport, keyword()}
          | :stop_viewport
          | {:schedule, timer(), non_neg_integer(), non_neg_integer()}
          | {:yield, :milkdrop}
          | :reclaim
          | {:milkdrop_cmd, milkdrop_cmd()}
          | :ensure_pack

  @type t :: %__MODULE__{
          mode: Mode.t(),
          mode_explicit: boolean(),
          playback: playback(),
          party: party(),
          overlay_hidden: boolean(),
          blanked: boolean(),
          focus: focus(),
          tv_presence: tv_presence(),
          binding: binding() | nil,
          seq: non_neg_integer(),
          metadata: map() | nil,
          metadata_at: integer() | nil,
          progress_frozen: boolean(),
          controller: map() | nil,
          group: map() | nil,
          color: map() | nil,
          artwork: map() | nil,
          idle: {:idle | :party, non_neg_integer()} | nil,
          idle_gen: non_neg_integer(),
          power: :on | :off,
          viz: viz(),
          claimed: String.t() | nil,
          size: size() | nil,
          viewport: viewport(),
          pack: pack(),
          milkdrop: milkdrop(),
          config: map()
        }

  defstruct mode: :now_playing,
            mode_explicit: false,
            playback: :stopped,
            party: :off,
            overlay_hidden: false,
            blanked: false,
            focus: :play_pause,
            tv_presence: :unknown,
            binding: nil,
            seq: 0,
            metadata: nil,
            metadata_at: nil,
            progress_frozen: false,
            controller: nil,
            group: nil,
            color: nil,
            artwork: nil,
            idle: nil,
            idle_gen: 0,
            power: :on,
            viz: nil,
            claimed: nil,
            size: nil,
            viewport: %{
              status: :idle,
              gen: 0,
              rung: 0,
              crashes: 0,
              crash_key: nil,
              delay_ms: nil,
              reason: nil,
              port: nil
            },
            pack: nil,
            milkdrop: %{
              yield: false,
              active: false,
              latch: nil,
              crashes: [],
              hold: nil,
              notice: nil,
              ensure: false,
              gen: 0
            },
            config: @defaults

  @doc """
  A new model. Options override the timing defaults: `:idle_ms`,
  `:party_idle_ms`, `:restart_ms`, `:restart_max_ms`, `:stable_ms`,
  `:crash_limit` and `:ladder` (a list of renderer start options, tried
  in order). `:milkdrop` (default false) turns the MilkDrop mode on, with
  `:milkdrop_crash_limit`, `:milkdrop_crash_window_ms`,
  `:milkdrop_retry_ms` and `:milkdrop_notice_ms`.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    config =
      opts
      |> Keyword.take(Map.keys(@defaults))
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    %__MODULE__{config: Map.merge(@defaults, config)}
  end

  @doc "The focus order of the transport controls."
  @spec focus_order() :: [focus()]
  def focus_order, do: @focus_order

  # ── Screen ───────────────────────────────────────────────────────────

  @doc "What the screen shows (see the moduledoc for the priority)."
  @spec screen(t()) :: screen()
  def screen(%__MODULE__{} = m) do
    cond do
      m.mode == :off or m.blanked -> :blank
      m.mode == :party_qr -> if party_on?(m), do: :party_qr, else: :party_off
      m.viewport.status == :yielded -> :milkdrop
      m.playback == :playing -> view(m, party_on?(m) and not m.overlay_hidden)
      party_on?(m) -> :party_qr
      true -> view(m, false)
    end
  end

  # The MilkDrop mode on Emerge (not yielded): preparing the pack, a pack
  # error notice, or the bar visualizer.
  defp view(%{mode: :milkdrop} = m, overlay?) do
    cond do
      not milkdrop_mode?(m) -> {:visualizer, overlay?}
      match?({:downloading, _pct}, m.pack) -> {:milkdrop_preparing, elem(m.pack, 1)}
      m.pack == :absent -> {:milkdrop_preparing, nil}
      m.milkdrop.notice != nil -> :milkdrop_error
      true -> {:visualizer, overlay?}
    end
  end

  defp view(m, overlay?), do: {m.mode, overlay?}

  @doc """
  The DRM connector the viewport drives: `HDMI-A-<port + 1>` for the bound
  output's HDMI port, `nil` while that port is unknown (the renderer then
  picks the first connected HDMI connector).
  """
  @spec viewport_connector(t()) :: String.t() | nil
  def viewport_connector(%__MODULE__{viewport: %{port: port}}) when is_integer(port),
    do: hdmi_connector(port)

  def viewport_connector(%__MODULE__{}), do: nil

  defp hdmi_connector(port), do: "HDMI-A-#{port + 1}"

  @doc "Whether the model wants the MilkDrop renderer on screen."
  @spec milkdrop_yield?(t()) :: boolean()
  def milkdrop_yield?(%__MODULE__{milkdrop: %{yield: yield?}}), do: yield?

  @doc "Whether a party is on."
  @spec party_on?(t()) :: boolean()
  def party_on?(%__MODULE__{party: party}), do: is_map(party)

  @doc "The visualizer the screen shows: `:strip`, `:full` or `nil`."
  @spec viz_wanted(t()) :: viz()
  def viz_wanted(%__MODULE__{} = m) do
    if m.viewport.status == :running and m.playback == :playing and viz_source?(m) do
      case screen(m) do
        {:now_playing, _overlay} -> :strip
        {:visualizer, _overlay} -> :full
        _other -> nil
      end
    end
  end

  defp viz_source?(%{binding: %{client_id: id}}) when is_binary(id), do: true
  defp viz_source?(_model), do: false

  # ── Reducer ──────────────────────────────────────────────────────────

  @doc "Applies one event. `now` is a monotonic time in ms."
  @spec handle(t(), event(), integer()) :: {t(), [effect()]}
  def handle(%__MODULE__{} = m, event, now) do
    {next, effects, opts} = apply_event(m, event, now)
    reconcile(m, reanchor(m, next, now), effects, opts)
  end

  # Leaving playback without new metadata (a pause or stream end the
  # player didn't re-time) freezes the progress where it got to, instead of
  # it jumping back to the last metadata's position; entering playback
  # continues from such a frozen anchor without counting the paused time.
  # Metadata with its own timing (fresh from the server, or re-timed by the
  # player) is used as it is.
  defp reanchor(%{playback: old, metadata: meta}, %{playback: new, metadata: meta} = next, now)
       when old != new and is_map(meta) do
    cond do
      old == :playing ->
        %{next | metadata: Progress.anchor(meta, now, true), progress_frozen: true}

      new == :playing and next.progress_frozen ->
        %{next | metadata: Progress.anchor(meta, now, false), progress_frozen: false}

      true ->
        next
    end
  end

  defp reanchor(%{metadata: meta}, %{metadata: meta} = next, _now), do: next
  defp reanchor(_old, next, _now), do: %{next | progress_frozen: false}

  # Each clause returns {model, effects, opts}; `opts[:restart_idle]`
  # restarts the idle timer even when its kind is unchanged (activity).

  defp apply_event(m, {:bound, binding, persisted}, _now) do
    cond do
      binding == m.binding ->
        {m, [], []}

      is_nil(binding) ->
        {clear_player(%{forget_tv(m, binding) | binding: nil}), [], []}

      true ->
        m = forget_tv(m, binding)
        same_key? = match?(%{key: key} when key == binding.key, m.binding)
        m = if same_key?, do: %{m | binding: binding}, else: clear_player(%{m | binding: binding})
        {m, mode_effects} = adopt_mode(m, persisted, same_key?)
        snapshot = if same_key?, do: [], else: [{:snapshot, binding.key}]
        {m, move_effects} = follow_port(m)
        {m, mode_effects ++ snapshot ++ move_effects, []}
    end
  end

  defp apply_event(m, {:snapshot, seq, snapshot}, now) do
    m =
      %{
        m
        | seq: seq,
          metadata: Map.get(snapshot, :metadata),
          metadata_at: now,
          controller: Map.get(snapshot, :controller_state),
          group: Map.get(snapshot, :group),
          color: Map.get(snapshot, :color),
          artwork: Map.get(snapshot, :artwork)
      }

    playback_from_group(m, m.group)
  end

  defp apply_event(m, {:display_event, seq, _event}, _now) when seq <= m.seq, do: {m, [], []}

  defp apply_event(m, {:display_event, seq, event}, now) do
    m = %{m | seq: seq}

    case Map.get(event, :event) do
      "metadata" -> {%{m | metadata: event, metadata_at: now}, [], []}
      "metadata_clear" -> {%{m | metadata: nil, metadata_at: nil}, [], []}
      "controller_state" -> {%{m | controller: event}, [], []}
      "controller_clear" -> {%{m | controller: nil}, [], []}
      "group" -> playback_from_group(%{m | group: event}, event)
      "group_clear" -> set_playback(%{m | group: nil}, :stopped)
      "color" -> {%{m | color: event}, [], []}
      "color_clear" -> {%{m | color: nil}, [], []}
      "artwork" -> {put_artwork(m, event), [], []}
      "artwork_clear" -> {clear_artwork(m, event), [], []}
      _other -> {m, [], []}
    end
  end

  defp apply_event(m, {:player, :started}, _now) do
    # A fresh player numbers its display events from 1 and starts with
    # its visualizer off: forget both so the snapshot and viz re-apply.
    m = %{clear_player(m) | viz: nil}
    effects = if m.binding, do: [{:snapshot, m.binding.key}], else: []
    {m, effects, []}
  end

  defp apply_event(m, {:player, :stopped}, _now), do: {clear_player(m), [], []}

  defp apply_event(m, {:stream, :start}, _now), do: set_playback(m, :playing)

  defp apply_event(m, {:stream, :end}, _now) do
    if m.playback == :playing, do: set_playback(m, :stopped), else: {m, [], []}
  end

  defp apply_event(%{mode: :off} = m, {:key, _key}, _now), do: {m, [], []}

  defp apply_event(%{blanked: true} = m, {:key, _key}, _now),
    do: {%{m | blanked: false}, [], restart_idle: true}

  defp apply_event(m, {:key, key}, _now) do
    {m, effects} = apply_key(m, key)
    {m, effects, restart_idle: true}
  end

  defp apply_event(m, {:set_mode, mode}, _now) do
    {m, effects} = change_mode(m, mode, push: :always)

    if mode == :off,
      do: {m, effects, []},
      else: {%{m | blanked: false}, effects, restart_idle: true}
  end

  defp apply_event(m, {:party, :off}, _now), do: {%{m | party: :off}, [], []}

  defp apply_event(m, {:party, %{url: _} = party}, _now) do
    if party == m.party do
      {m, [], []}
    else
      wake? = not party_on?(m) or party.url != m.party.url
      m = %{m | party: party, overlay_hidden: false}
      if wake?, do: {%{m | blanked: false}, [], restart_idle: true}, else: {m, [], []}
    end
  end

  defp apply_event(m, {:tv_presence, :unknown}, _now), do: {m, [], []}

  defp apply_event(m, {:tv_presence, presence}, _now) when presence in [:present, :absent],
    do: {%{m | tv_presence: presence}, [], []}

  defp apply_event(m, {:timer, :idle, gen}, _now) do
    if gen == m.idle_gen and m.idle != nil,
      do: {%{m | blanked: true}, [], []},
      else: {m, [], []}
  end

  defp apply_event(m, {:timer, :milkdrop_retry, gen}, _now) do
    if gen == m.milkdrop.hold, do: {put_md(m, hold: nil), [], []}, else: {m, [], []}
  end

  defp apply_event(m, {:timer, :milkdrop_notice, gen}, _now) do
    if gen == m.milkdrop.notice, do: {put_md(m, notice: nil), [], []}, else: {m, [], []}
  end

  defp apply_event(m, {:timer, :retry, gen}, _now) do
    if gen == m.viewport.gen and m.viewport.status in [:backoff, :failed],
      do: start_viewport(m),
      else: {m, [], []}
  end

  defp apply_event(m, {:timer, :stable, gen}, _now) do
    if gen == m.viewport.gen and m.viewport.status == :running,
      do: {put_vp(m, crashes: 0, crash_key: nil, delay_ms: nil), [], []},
      else: {m, [], []}
  end

  defp apply_event(m, {:display_available, available?}, _now) do
    case {available?, m.viewport.status} do
      {true, status} when status in [:idle, :headless] -> start_viewport(m)
      {false, status} when status in [:idle, :headless] -> {put_vp(m, status: :headless), [], []}
      _other -> {m, [], []}
    end
  end

  defp apply_event(m, {:viewport, :started}, _now) do
    gen = m.viewport.gen + 1
    m = put_vp(m, status: :running, gen: gen, reason: nil)
    # A new viewport shows the current screen and power, and needs the
    # visualizer source again.
    {%{m | viz: nil},
     [:render, {:display, m.power}, {:schedule, :stable, gen, cfg(m, :stable_ms)}], []}
  end

  defp apply_event(m, {:viewport, :start_failed, reason}, _now) do
    if m.viewport.status == :starting, do: backoff(m, reason), else: {m, [], []}
  end

  defp apply_event(m, {:viewport, :down, reason}, _now) do
    cond do
      m.viewport.status != :running -> {m, [], []}
      crash?(reason) -> crashed(m, reason)
      true -> backoff(put_vp(m, delay_ms: nil), reason)
    end
  end

  # The output size the running viewport reports (the mode it chose).
  defp apply_event(m, {:viewport_size, {w, h} = size}, _now)
       when is_integer(w) and w > 0 and is_integer(h) and h > 0,
       do: {%{m | size: size}, [], []}

  defp apply_event(m, :hdmi_link_up, _now) do
    if m.viewport.status in [:backoff, :failed],
      do: start_viewport(put_vp(m, crashes: 0, crash_key: nil, delay_ms: nil)),
      else: {m, [], []}
  end

  # A new Pack process (the old one crashed, its download with it): its
  # status replaces the cached one and the pack may be asked for again.
  defp apply_event(m, {:pack_restarted, status}, now),
    do: apply_event(put_md(m, ensure: false), {:pack, status}, now)

  defp apply_event(m, {:pack, status}, _now) do
    cond do
      status == m.pack -> {m, [], []}
      pack_error?(status) and milkdrop_mode?(m) -> notice(%{m | pack: status})
      true -> {%{m | pack: status}, [], []}
    end
  end

  # The owner stopped the viewport for the renderer.
  defp apply_event(m, {:milkdrop, :yielded}, _now) do
    if m.milkdrop.active,
      do: {put_vp(m, status: :yielded, gen: m.viewport.gen + 1, reason: nil), [], []},
      else: {m, [], []}
  end

  # The renderer dropped the display: the viewport takes it back at once.
  defp apply_event(m, {:milkdrop, :released}, _now), do: restart_yielded(m)

  defp apply_event(m, {:milkdrop, :ended, outcome}, now) do
    {m, effects} = m |> put_md(yield: false, active: false) |> milkdrop_outcome(outcome, now)
    {m, start_effects, []} = restart_yielded(m)
    {m, effects ++ start_effects, []}
  end

  defp apply_event(m, _event, _now), do: {m, [], []}

  # ── Keys ─────────────────────────────────────────────────────────────

  defp apply_key(%{milkdrop: %{yield: true}} = m, key) when key in [:left, :right, :select],
    do: {m, [{:milkdrop_cmd, milkdrop_key(key)}]}

  defp apply_key(m, :left), do: {move_focus(m, -1), []}
  defp apply_key(m, :right), do: {move_focus(m, 1), []}
  defp apply_key(m, :up), do: change_mode(m, Mode.cycle(m.mode, -1, milkdrop?(m)))
  defp apply_key(m, :down), do: change_mode(m, Mode.cycle(m.mode, 1, milkdrop?(m)))
  defp apply_key(%{focus: :prev} = m, :select), do: controller(m, :previous)
  defp apply_key(%{focus: :next} = m, :select), do: controller(m, :next)
  defp apply_key(m, :select), do: controller(m, toggle(m))
  defp apply_key(m, :play), do: controller(m, :play)
  defp apply_key(m, :pause), do: controller(m, :pause)
  defp apply_key(m, :play_pause), do: controller(m, toggle(m))
  defp apply_key(m, :stop), do: controller(m, :stop)
  defp apply_key(m, :forward), do: controller(m, :next)
  defp apply_key(m, :backward), do: controller(m, :previous)

  defp apply_key(m, :exit) do
    cond do
      match?({_view, true}, screen(m)) -> {%{m | overlay_hidden: true}, []}
      m.mode != :now_playing -> change_mode(m, :now_playing)
      true -> {m, []}
    end
  end

  defp apply_key(m, _key), do: {m, []}

  defp milkdrop_key(:left), do: :prev
  defp milkdrop_key(:right), do: :next
  defp milkdrop_key(:select), do: :toggle_lock

  defp toggle(%{playback: :playing}), do: :pause
  defp toggle(_model), do: :play

  defp controller(%{binding: %{key: _}} = m, command), do: {m, [{:controller, command}]}
  defp controller(m, _command), do: {m, []}

  defp move_focus(m, step) do
    index = Enum.find_index(@focus_order, &(&1 == m.focus)) || 1
    next = (index + step) |> max(0) |> min(length(@focus_order) - 1)
    %{m | focus: Enum.at(@focus_order, next)}
  end

  # ── Modes ────────────────────────────────────────────────────────────

  # A user's mode choice: persisted (when bound) and pushed to Home
  # Assistant. `push: :always` echoes it even when unchanged (an HA
  # command expects a state back).
  #
  # Every explicit choice starts a new MilkDrop session: a latch, a retry
  # hold and the failure count are forgotten, and picking MilkDrop again
  # after a pack error retries the pack.
  # MilkDrop while it is off is refused (Home Assistant gets the real mode).
  defp change_mode(m, mode, opts \\ []) do
    if mode == :milkdrop and not milkdrop?(m),
      do: {m, if(opts[:push] == :always, do: [{:push_mode, m.mode}], else: [])},
      else: put_mode(m, mode, opts)
  end

  defp put_mode(m, mode, opts) do
    changed? = mode != m.mode

    m =
      put_md(%{m | mode: mode, mode_explicit: true},
        latch: nil,
        hold: nil,
        crashes: [],
        notice: nil,
        ensure: false
      )

    persist = if changed? and m.binding, do: [{:persist_mode, mode}], else: []
    push = if changed? or opts[:push] == :always, do: [{:push_mode, mode}], else: []
    {m, retry} = if mode == :milkdrop, do: retry_pack(m), else: {m, []}
    {m, persist ++ push ++ retry}
  end

  defp retry_pack(m) do
    if pack_error?(m.pack) do
      {m, effects, []} = notice(put_md(m, ensure: true))
      {m, [:ensure_pack | effects]}
    else
      {m, []}
    end
  end

  # A newly bound output brings its persisted mode, unless the user chose
  # one this boot before it was bound: then that choice is persisted.
  defp adopt_mode(m, persisted, same_key?) do
    cond do
      m.mode_explicit and not same_key? -> {m, [{:persist_mode, m.mode}]}
      m.mode_explicit -> {m, []}
      is_nil(persisted) or persisted == m.mode -> {m, []}
      persisted == :milkdrop and not milkdrop?(m) -> {m, []}
      true -> {%{m | mode: persisted}, [{:push_mode, persisted}]}
    end
  end

  # ── Player state ─────────────────────────────────────────────────────

  defp clear_player(m) do
    %{
      m
      | seq: 0,
        playback: :stopped,
        metadata: nil,
        metadata_at: nil,
        controller: nil,
        group: nil,
        color: nil,
        artwork: nil
    }
  end

  defp playback_from_group(m, %{playback_state: "playing"}), do: set_playback(m, :playing)
  defp playback_from_group(m, %{playback_state: "paused"}), do: set_playback(m, :paused)
  defp playback_from_group(m, %{playback_state: "stopped"}), do: set_playback(m, :stopped)
  defp playback_from_group(m, _group), do: {m, [], []}

  defp set_playback(m, :playing) do
    if m.playback == :playing,
      do: {m, [], []},
      else: {%{m | playback: :playing, blanked: false}, [], restart_idle: true}
  end

  defp set_playback(m, playback), do: {%{m | playback: playback}, [], []}

  # The UI shows artwork slot 0.
  defp put_artwork(m, %{slot: slot}) when slot != 0, do: m
  defp put_artwork(m, event), do: %{m | artwork: event}

  defp clear_artwork(m, %{slot: slot}) when slot != 0, do: m
  defp clear_artwork(m, _event), do: %{m | artwork: nil}

  # ── Viewport lifecycle ───────────────────────────────────────────────

  # The viewport drives the bound output's own connector (HDMI port N is
  # DRM connector HDMI-A-<N+1>); with no port known the renderer picks the
  # first connected HDMI connector.
  defp start_viewport(m) do
    port = bound_port(m)
    rung = Enum.at(cfg(m, :ladder), m.viewport.rung, [])
    rung = if port, do: Keyword.put(rung, :connector, hdmi_connector(port)), else: rung

    {put_vp(m, status: :starting, gen: m.viewport.gen + 1, port: port), [{:start_viewport, rung}],
     []}
  end

  # Another CEC adapter (or none) means another TV: what was known about
  # the old one doesn't carry over.
  defp forget_tv(m, binding) do
    if cec_dev(m.binding) == cec_dev(binding), do: m, else: %{m | tv_presence: :unknown}
  end

  defp cec_dev(%{cec_dev: dev}), do: dev
  defp cec_dev(_binding), do: nil

  # A running viewport on another port than the bound output's moves there.
  defp follow_port(m) do
    port = bound_port(m)

    if m.viewport.status == :running and port != nil and port != m.viewport.port do
      {m, effects, []} = start_viewport(m)
      {m, [:stop_viewport | effects]}
    else
      {m, []}
    end
  end

  defp bound_port(%{binding: %{hdmi_port: port}}) when is_integer(port), do: port
  defp bound_port(_model), do: nil

  defp crash?(:normal), do: false
  defp crash?(:shutdown), do: false
  defp crash?({:shutdown, _reason}), do: false
  defp crash?(_reason), do: true

  defp crashed(m, reason) do
    key = crash_key(reason)
    vp = m.viewport
    crashes = if key == vp.crash_key, do: vp.crashes + 1, else: 1
    last_rung = length(cfg(m, :ladder)) - 1

    cond do
      crashes < cfg(m, :crash_limit) ->
        backoff(put_vp(m, crashes: crashes, crash_key: key), reason)

      vp.rung < last_rung ->
        # The next renderer rung, after the usual first delay.
        backoff(put_vp(m, rung: vp.rung + 1, crashes: 0, crash_key: nil, delay_ms: nil), reason)

      true ->
        # Out of rungs: keep retrying the last one at the longest delay.
        delay = cfg(m, :restart_max_ms)
        gen = vp.gen + 1

        m =
          put_vp(m,
            status: :failed,
            gen: gen,
            crashes: crashes,
            crash_key: key,
            delay_ms: delay,
            reason: reason
          )

        {m, [{:schedule, :retry, gen, delay}], []}
    end
  end

  defp backoff(m, reason) do
    delay =
      case m.viewport.delay_ms do
        nil -> cfg(m, :restart_ms)
        previous -> min(previous * 2, cfg(m, :restart_max_ms))
      end

    gen = m.viewport.gen + 1

    {put_vp(m, status: :backoff, gen: gen, delay_ms: delay, reason: reason),
     [{:schedule, :retry, gen, delay}], []}
  end

  # What makes two crashes "the same": the exception module or error tag,
  # not the stacktrace or the details.
  defp crash_key({%{__exception__: true, __struct__: module}, _stack}), do: module
  defp crash_key({tag, _detail}) when is_atom(tag), do: tag
  defp crash_key(reason), do: reason

  defp put_vp(m, changes), do: %{m | viewport: Map.merge(m.viewport, Map.new(changes))}

  # ── MilkDrop ─────────────────────────────────────────────────────────

  defp milkdrop?(m), do: cfg(m, :milkdrop) == true

  # The MilkDrop mode with its own behaviour (not latched off to the bars).
  defp milkdrop_mode?(m), do: m.mode == :milkdrop and milkdrop?(m) and is_nil(m.milkdrop.latch)

  # Once yielded it stays wanted while the rest holds; a new yield needs a
  # running viewport to take the display from, on a known connector (the
  # renderer must present on the same one), and no session still ending.
  defp milkdrop_wanted?(m) do
    md = m.milkdrop

    milkdrop_mode?(m) and is_nil(md.hold) and m.playback == :playing and
      match?({:ready, _version, _dir}, m.pack) and viz_source?(m) and
      (md.yield or
         (not md.active and m.viewport.status == :running and viewport_connector(m) != nil))
  end

  defp pack_error?({:error, _reason}), do: true
  defp pack_error?(_status), do: false

  # Shows the pack error notice for `milkdrop_notice_ms`.
  defp notice(m) do
    gen = m.milkdrop.gen + 1

    {put_md(m, notice: gen, gen: gen),
     [{:schedule, :milkdrop_notice, gen, cfg(m, :milkdrop_notice_ms)}], []}
  end

  defp restart_yielded(m) do
    if m.viewport.status == :yielded, do: start_viewport(m), else: {m, [], []}
  end

  defp milkdrop_outcome(m, :requested, _now), do: {m, []}
  defp milkdrop_outcome(m, :thermal, _now), do: {put_md(m, latch: :thermal), []}

  defp milkdrop_outcome(m, {:crashed, _why}, now) do
    window = cfg(m, :milkdrop_crash_window_ms)
    crashes = [now | Enum.filter(m.milkdrop.crashes, &(now - &1 < window))]

    if length(crashes) >= cfg(m, :milkdrop_crash_limit) do
      {put_md(m, latch: :crashed, crashes: crashes), []}
    else
      gen = m.milkdrop.gen + 1

      {put_md(m, crashes: crashes, hold: gen, gen: gen),
       [{:schedule, :milkdrop_retry, gen, cfg(m, :milkdrop_retry_ms)}]}
    end
  end

  defp put_md(m, changes), do: %{m | milkdrop: Map.merge(m.milkdrop, Map.new(changes))}

  # ── Reconcile derived state into effects ─────────────────────────────

  defp reconcile(old, m, effects, opts) do
    {m, idle_effects} = reconcile_idle(m, Keyword.get(opts, :restart_idle, false))
    {m, power_effects} = reconcile_power(m)
    {m, viz_effects} = reconcile_viz(m)
    {m, milkdrop_effects} = reconcile_milkdrop(m)
    {m, claim_effects} = reconcile_claim(m)

    render =
      if :render not in effects and render_key(old) != render_key(m), do: [:render], else: []

    {m,
     effects ++
       render ++ power_effects ++ viz_effects ++ milkdrop_effects ++ claim_effects ++ idle_effects}
  end

  defp reconcile_milkdrop(m) do
    wanted? = milkdrop_wanted?(m)
    md = m.milkdrop

    cond do
      wanted? and not md.yield ->
        {put_md(m, yield: true, active: true), [{:yield, :milkdrop}]}

      md.yield and not wanted? ->
        {put_md(m, yield: false), [:reclaim]}

      milkdrop_mode?(m) and m.pack == :absent and not md.ensure ->
        {put_md(m, ensure: true), [:ensure_pack]}

      true ->
        {m, []}
    end
  end

  defp idle_kind(m) do
    cond do
      m.mode == :off or m.blanked or m.playback == :playing -> nil
      party_on?(m) -> :party
      true -> :idle
    end
  end

  defp reconcile_idle(m, restart?) do
    kind = idle_kind(m)
    current = m.idle && elem(m.idle, 0)

    cond do
      kind == current and not (restart? and kind != nil) ->
        {m, []}

      is_nil(kind) ->
        {%{m | idle: nil, idle_gen: m.idle_gen + 1}, []}

      true ->
        gen = m.idle_gen + 1
        ms = if kind == :party, do: cfg(m, :party_idle_ms), else: cfg(m, :idle_ms)
        {%{m | idle: {kind, gen}, idle_gen: gen}, [{:schedule, :idle, gen, ms}]}
    end
  end

  defp reconcile_power(m) do
    power = if screen(m) == :blank, do: :off, else: :on
    if power == m.power, do: {m, []}, else: {%{m | power: power}, [{:display, power}]}
  end

  defp reconcile_viz(m) do
    viz = viz_wanted(m)
    if viz == m.viz, do: {m, []}, else: {%{m | viz: viz}, [{:viz, viz}]}
  end

  defp reconcile_claim(m) do
    wanted =
      case m.binding do
        %{cec_dev: dev} when is_binary(dev) and m.mode != :off -> dev
        _other -> nil
      end

    cond do
      wanted == m.claimed -> {m, []}
      is_nil(m.claimed) -> {%{m | claimed: wanted}, [{:claim_keys, wanted}]}
      is_nil(wanted) -> {%{m | claimed: nil}, [{:release_keys, m.claimed}]}
      true -> {%{m | claimed: wanted}, [{:release_keys, m.claimed}, {:claim_keys, wanted}]}
    end
  end

  # Everything `UniversalProxy.Display.View` draws from.
  defp render_key(m) do
    {screen(m), m.focus, m.tv_presence, m.playback, m.metadata, m.controller, m.color, m.artwork,
     m.party, m.group && Map.get(m.group, :group_name), m.size}
  end

  defp cfg(m, key), do: Map.fetch!(m.config, key)
end
