defmodule UniversalProxy.TuyaBeaconMesh.Radio do
  @moduledoc """
  The board's single P2 radio: owns the controller lease, discovery and the
  advert receiver for one adapter, serialises transmissions, and fans
  received frames out to subscribers.

  `Bluez.Radio` and `Bluez.Mgmt` must already be running: they are shared
  infrastructure the host supervises, and this process never starts or
  links them. Setup (on start, and again after any loss):

    * opens its own system-bus connection (kept across retries) and, when
      `:adapter_address` is given, checks that `/org/bluez/hci<index>` is
      still that adapter (`Adapter1.Address`). An index is reused when a
      dongle is unplugged and another takes its place, so a mismatch fails
      setup with `{:wrong_adapter, address}` before anything below touches
      the adapter (no lease, no power, no discovery, no advert), and setup
      keeps retrying;
    * checks the adapter through `Bluez.Mgmt` (*Read Advertising
      Features*), subscribes to `Bluez.Radio`'s lease-end notices and
      acquires the `:mgmt` lease for the adapter — this process is the
      lease holder, so only it may advertise;
    * powers the adapter (`Adapter1.Powered = true`: `Bluez.Client` powers
      only the adapter it claims, and a dedicated mesh adapter is never
      claimed) and starts LE discovery with `DuplicateData: true` on it;
    * starts a linked `Bluez.AdvertReceiver` whose `on_report:` callback
      casts only AD 0x03 26-byte frames here.

  When any step fails — `Bluez.Radio`/`Bluez.Mgmt` not running, adapter
  missing, lease held by another process, D-Bus down — the radio stays up
  but not ready: whatever the attempt got (lease, discovery) is undone,
  the reason is logged once (`status/1`'s `:last_error`), and setup is
  retried after 2 s, doubling up to 30 s. The same happens at runtime when
  the lease ends, `Bluez.Radio` or the D-Bus connection goes down, the
  receiver exits, `Bluez.Mgmt` stops accepting sends, or a health check
  fails. While not ready,
  `send_frame/3` returns `{:error, :not_ready}` (queued frames are
  dropped); subscriptions are kept and deliver again once ready.

  Some losses leave every process alive: an adapter removed or a
  `bluetoothd` restart ends discovery while the D-Bus connection, the
  lease and the receiver (which reopens its HCI socket on its own)
  survive. So while ready, every `:health_check_ms` (default 15 s) the
  radio checks that the receiver is `listening?`, that the adapter's
  `org.bluez.Adapter1.Discovering` is true and (with `:adapter_address`)
  that the index still names that adapter, and re-runs setup (which
  restarts discovery, or refuses a replaced adapter) when any is not. A failure that comes back right
  after the re-setup it caused is logged once, until a check passes.

  On stop it takes any advert off air, stops the receiver and discovery
  and releases the lease. `Bluez.Radio`/`Bluez.Mgmt` are left running.

  ## Wedged controller

  A controller can wedge with every process healthy and every check above
  passing: discovery on, receiver listening, lease held, no advertising
  instance registered, yet every advertise is refused by the controller
  (seen on an RTL8761B after hours of uptime: *LE Set Extended
  Advertising Enable* failing with `EMLINK`, which MGMT reports as
  `:failed`). Only advertising shows it, so the radio counts advertise
  refusals that mean a controller fault (MGMT `:failed` and `:timeout`).
  Per-frame refusals (`:busy`, `:rotation_busy`, `:rejected`,
  `:invalid_params`, …) and the uncertain ones (above) neither count nor
  reset the count; an accepted advertise resets it. After
  `:wedge_failures` (default 3) in a row, or a run of them spanning more
  than `:wedge_window_ms` (default 30 s), the controller is declared
  wedged: `:last_error` becomes `{:controller_wedged, mgmt_status}`, and
  the radio tears down and goes not ready like any other loss, so sends
  get `{:error, :not_ready}` until it is back.

  Recovery is the next setup, after `:wedge_retry_ms` (default 5 s,
  doubling per wedge up to `:max_wedge_retry_ms`, 60 s; reset by an
  accepted advertise), with a controller reset added: right after the
  adapter fence passes and before the lease is taken, the adapter is
  power-cycled (`Adapter1.Powered` false, then true, on
  `/org/bluez/hci<index>`). The kernel closes the controller on power-off
  and re-initialises it on power-on, which clears its advertising state.
  `Bluez.Mgmt` exposes no separate HCI Reset, so there is no stronger
  in-band step: a wedge that comes back before any advertise was accepted
  (`:wedge_streak` 2 or more) is logged at error level and sets
  `:controller_reset_needed`, and the radio keeps power-cycling on the
  backoff above. Only resetting the transport (for a USB dongle, a port
  reset or `btusb` unbind/bind) is left, and that is the host's call.

  Hosts reading `status/1`: `:controller_reset_needed` means "reset the
  controller's transport", and stays set until an advertise is accepted
  again; `:wedges` / `:recoveries` count wedges detected and power-cycles
  done since start, and `:last_wedge_at` / `:last_recovery_at` are their
  UTC times. While recovering, `ready` is false with `last_error`
  `{:controller_wedged, _}`: show the radio as down, not the bulbs. A
  frame refused while the controller was failing (before the wedge was
  declared) is `{:error, {:advertise, :failed}}` and was not transmitted;
  presence logic should treat it, like `:not_ready`, as no verdict.

  ## TX

  `send_frame/3` queues a 26-byte frame for `duration_ms` of advertising
  (20/30 ms interval, connectable, no kernel `duration_ms:` — on a
  controller without hardware offload `Bluez.Mgmt` refuses a finite
  duration while another instance is registered, see its "Software
  rotation" section, so we stop on our own timer). One advert is on air at
  a time, in the order sent, so sequence numbers go on air in the order
  they were handed out. Frames are sent with the app's queue classes
  (tuya_beacon_mesh.md §4.7): a `:control` send (reset, group)
  drops queued `:normal` sends (DP, ping); it does not interrupt the
  advert already on air.

  With every frame on air for seconds, the queue is latency: it holds at
  most `:max_queue` frames (default 8; `{:error, :queue_full}` past
  that), and a `:normal` send with a `coalesce:` key replaces a queued
  frame with the same key (the old one is dropped and the new one goes to
  the back, keeping the send order). A frame dropped from the queue never
  went on air.

  ## RX

  `subscribe/3` registers a pid for `{:tuya_report, report}` messages,
  where `report` is `%{mac, address, frame, rssi}` (`mac` is the 12-hex
  advertiser address, `frame` the raw 26 bytes as received, hop bits
  intact). Filters: `:all`, `:unpaired` (frames `P2.parse_unpaired/1`
  accepts), or `{:mac, mac}`.

  Two kinds of duplicates are dropped before fan-out: the same
  `{address, P2.normalize(frame)}` seen within ~2 s (bulbs relay copies
  with decremented hop/TTL bits, which `normalize/1` erases), and echoes of
  our own recent transmissions (the last #{32} normalised frames sent)
  relayed back by bulbs. Echo dropping can be turned off with
  `drop_echoes: false` / `set_drop_echoes/2` — checking on hardware that
  a transmission was relayed needs that, since a relayed copy of our frame
  is exactly what it looks for.

  The `Bluez.*` modules are injectable (`:bluez_radio`, `:mgmt`,
  `:rebus`, `:dbus`, `:receiver` options) so the queue and fan-out logic
  is testable off-board.
  """

  use GenServer

  require Logger

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, P2}

  @dedupe_ms 2_000
  @dedupe_max 1_024
  @recent_tx_max 32
  @retry_ms 2_000
  @max_retry_ms 30_000

  @max_queue 8
  @receiver_stop_ms 2_000
  @health_check_ms 15_000
  # Kept short: the check runs in this process's loop.
  @health_call_ms 2_000
  @props_iface "org.freedesktop.DBus.Properties"
  @adapter_iface "org.bluez.Adapter1"

  # Advertise errors that mean the lease or Bluez.Mgmt is gone, not that
  # this one frame was refused: re-run setup rather than keep sending.
  # They don't prove the frame stayed off air (Mgmt can crash mid-request,
  # and reports :lease_expired for an instance that already went on air),
  # so the caller hears {:uncertain, reason}, not :not_ready.
  @fatal_advertise_errors [:lease_expired, :not_lease_holder, :not_running]

  # MGMT statuses for an advertise the controller itself failed (HCI
  # command errors the kernel has no specific status for, and HCI command
  # timeouts), as opposed to a refusal of this frame. See "Wedged
  # controller".
  @wedge_advertise_errors [:failed, :timeout]
  @wedge_failures 3
  @wedge_window_ms 30_000
  @wedge_retry_ms 5_000
  @max_wedge_retry_ms 60_000

  # ── Client API ─────────────────────────────────────────────────────────

  @doc """
  Starts the radio for one adapter.

  Options: `:adapter_index` (default 0), `:adapter_address` (the
  adapter's expected MAC, any case; `nil`, the default, skips the check),
  `:name` (default
  `#{inspect(__MODULE__)}`), `:drop_echoes` (default `true`),
  `:retry_ms` (first setup retry delay, default #{@retry_ms}; doubles up
  to #{@max_retry_ms}), `:max_queue` (default #{@max_queue}),
  `:receiver_stop_ms` (how long a stopping receiver may take before it is
  killed, default #{@receiver_stop_ms}), `:health_check_ms` (interval of
  the health check while ready, default #{@health_check_ms}),
  `:wedge_failures` (default #{@wedge_failures}), `:wedge_window_ms`
  (default #{@wedge_window_ms}), `:wedge_retry_ms` (default
  #{@wedge_retry_ms}) and `:max_wedge_retry_ms` (default
  #{@max_wedge_retry_ms}) (see "Wedged controller"), and the
  `Bluez.*` implementation
  modules `:bluez_radio`, `:mgmt`, `:rebus`, `:dbus`, `:receiver`
  (defaults are the real ones).

  Every client function takes `server:` (default `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # Teardown can take several seconds when BlueZ is slow; a kill is still
  # safe (Bluez.Radio ends the lease, the D-Bus connection closes).
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :adapter_index, 0)},
      start: {__MODULE__, :start_link, [opts]},
      shutdown: 10_000
    }
  end

  @doc """
  Queues `frame` (26 bytes) for `duration_ms` of advertising.

  Options: `:class` — `:normal` (default) or `:control`; a `:control`
  send drops queued `:normal` frames. `:coalesce` — a key; a `:normal`
  send replaces a queued frame with the same key (see the moduledoc).
  `:timeout` — call timeout (default 5000). `:server`.

  `:ok` means accepted for transmission: on air, or queued. A queued frame
  can still be dropped later (a `:control` send, a coalescing send, the
  radio going not ready, the adapter refusing it — logged).

  Errors, all meaning the frame was **not** transmitted unless noted:
  `{:error, :not_ready}` while setup is pending or being retried (see the
  moduledoc; refused before reaching `Bluez.Mgmt`), `{:error,
  :queue_full}`, `{:error, {:advertise, reason}}` when the adapter
  refused it (with `:failed` or `:timeout` this counts towards declaring
  the controller wedged, see the moduledoc), `{:error, :not_running}` when no radio process exists,
  `{:error, :bad_frame}` / `{:error, :bad_class}`. Not known either way:
  `{:error, :timeout}`, `{:error, :radio_exited}` (the radio died during
  the call), and `{:error, {:uncertain, reason}}` when `Bluez.Mgmt` or the
  lease went away during the advertise (`reason` is `:not_running`,
  `:lease_expired` or `:not_lease_holder`); the radio then re-runs setup
  as for any other loss.
  """
  @spec send_frame(binary(), non_neg_integer(), keyword()) ::
          :ok
          | {:error,
             :not_running
             | :not_ready
             | :queue_full
             | {:advertise, term()}
             | {:uncertain, :lease_expired | :not_lease_holder | :not_running}
             | :bad_frame
             | :bad_class
             | :timeout
             | :radio_exited}
  def send_frame(frame, duration_ms, opts \\ [])

  def send_frame(<<_::binary-size(26)>> = frame, duration_ms, opts)
      when is_integer(duration_ms) and duration_ms >= 0 do
    case Keyword.get(opts, :class, :normal) do
      class when class in [:normal, :control] ->
        request = {:send_frame, frame, duration_ms, class, Keyword.get(opts, :coalesce)}

        try do
          GenServer.call(server(opts), request, Keyword.get(opts, :timeout, 5_000))
        catch
          :exit, {:timeout, _} -> {:error, :timeout}
          # The call never reached a process: nothing was sent.
          :exit, {:noproc, _} -> {:error, :not_running}
          :exit, _reason -> {:error, :radio_exited}
        end

      _other ->
        {:error, :bad_class}
    end
  end

  def send_frame(frame, _duration_ms, _opts) when is_binary(frame),
    do: {:error, :bad_frame}

  @doc "Takes the current advert off air and empties the TX queue."
  @spec stop_tx(keyword()) :: :ok | {:error, :not_running}
  def stop_tx(opts \\ []) do
    call(server(opts), :stop_tx, {:error, :not_running})
  end

  @doc """
  `stop_tx/1`, and forgets `:last_tx_sn` (see `status/1`): for a
  controller switching to another mesh, whose earlier frames must neither
  air under the new mesh nor count as its progress. `opts`: `:server`,
  `:timeout` (default 5000).
  """
  @spec clear_tx(keyword()) :: :ok | {:error, :not_running}
  def clear_tx(opts \\ []) do
    call(server(opts), :clear_tx, {:error, :not_running}, Keyword.get(opts, :timeout, 5_000))
  end

  @doc """
  Subscribes `pid` to `{:tuya_report, report}` messages matching
  `filter` (`:all`, `:unpaired` or `{:mac, mac}`). The pid is monitored
  and dropped when it exits. Works while the radio is not ready; reports
  start once it is.
  """
  @spec subscribe(pid(), :all | :unpaired | {:mac, String.t()}, keyword()) ::
          :ok | {:error, :not_running | :bad_filter}
  def subscribe(pid, filter, opts \\ []) when is_pid(pid) do
    case normalize_filter(filter) do
      {:ok, filter} -> call(server(opts), {:subscribe, pid, filter}, {:error, :not_running})
      :error -> {:error, :bad_filter}
    end
  end

  @doc "Removes `pid`'s subscription, if any."
  @spec unsubscribe(pid(), keyword()) :: :ok | {:error, :not_running}
  def unsubscribe(pid, opts \\ []) when is_pid(pid) do
    call(server(opts), {:unsubscribe, pid}, {:error, :not_running})
  end

  @doc "Turns echo dropping (see the moduledoc) on or off at runtime."
  @spec set_drop_echoes(boolean(), keyword()) :: :ok | {:error, :not_running}
  def set_drop_echoes(drop?, opts \\ []) when is_boolean(drop?) do
    call(server(opts), {:set_drop_echoes, drop?}, {:error, :not_running})
  end

  @doc """
  Radio state: whether setup completed (`:ready`) and why it last failed
  (`:last_error`, `nil` once ready), adapter index and expected address,
  lease held, discovery on, receiver listening, subscriber count, what's
  on air (`:tx`), how many frames are queued (`:queued`), and the
  sequence number of the last frame the adapter accepted to advertise
  (`:last_tx_sn`, `nil` until one has or after `clear_tx/1`; a frame
  queued, coalesced away or advertised with an uncertain outcome doesn't
  count).

  Controller health (see "Wedged controller" in the moduledoc):
  `:advertise_failures` (controller-fault refusals since the last
  accepted advertise or wedge), `:wedges` (wedges detected since start),
  `:wedge_streak` (wedges since the last accepted advertise; 0 is
  healthy), `:recoveries` (power-cycles done), `:last_wedge_at` /
  `:last_recovery_at` (`DateTime` in UTC, or `nil`), and
  `:controller_reset_needed` (a power-cycle didn't clear the wedge: the
  host should reset the controller's transport).

  `opts`: `:server`, `:timeout` (default 5000; a radio that doesn't
  answer in time reads as not running).
  """
  @spec status(keyword()) :: {:ok, map()} | {:error, :not_running}
  def status(opts \\ []) do
    call(server(opts), :status, {:error, :not_running}, Keyword.get(opts, :timeout, 5_000))
  end

  defp server(opts), do: Keyword.get(opts, :server, __MODULE__)

  # `catch :exit` idiom (see `Bluez`): not running → the given default.
  defp call(server, request, default, timeout \\ 5_000) do
    GenServer.call(server, request, timeout)
  catch
    :exit, _reason -> default
  end

  defp normalize_filter(:all), do: {:ok, :all}
  defp normalize_filter(:unpaired), do: {:ok, :unpaired}

  defp normalize_filter({:mac, mac}) when is_binary(mac) do
    case normalize_mac(mac) do
      {:ok, mac} -> {:ok, {:mac, mac}}
      :error -> :error
    end
  end

  defp normalize_filter(_other), do: :error

  # "DC:23:53:0F:B3:4A", "dc23530fb34a" → "DC23530FB34A".
  defp normalize_mac(mac) do
    hex = mac |> String.replace(~r/[^0-9A-Fa-f]/, "") |> String.upcase()
    if byte_size(hex) == 12, do: {:ok, hex}, else: :error
  end

  defp mac_string(address) when is_integer(address) do
    address |> Integer.to_string(16) |> String.pad_leading(12, "0")
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    # Trapping exits turns a crash of the linked AdvertReceiver into an
    # {:EXIT, rx, _} we answer by re-running setup, instead of taking this
    # process (and its subscriptions and queue) down with it. It also makes
    # a supervisor shutdown run terminate/2, so the advert, discovery and
    # lease are cleaned up explicitly; gen_server still honours the
    # parent's EXIT itself before handle_info sees it.
    Process.flag(:trap_exit, true)
    retry_ms = Keyword.get(opts, :retry_ms, @retry_ms)
    wedge_retry_ms = Keyword.get(opts, :wedge_retry_ms, @wedge_retry_ms)

    state = %{
      adapter_index: Keyword.get(opts, :adapter_index, 0),
      adapter_address: opts |> Keyword.get(:adapter_address) |> upcase(),
      bluez_radio: Keyword.get(opts, :bluez_radio, Bluez.Radio),
      mgmt: Keyword.get(opts, :mgmt, Bluez.Mgmt),
      rebus: Keyword.get(opts, :rebus, Bluez.Rebus),
      dbus: Keyword.get(opts, :dbus, Bluez.DBus),
      receiver: Keyword.get(opts, :receiver, Bluez.AdvertReceiver),
      drop_echoes: Keyword.get(opts, :drop_echoes, true),
      max_queue: Keyword.get(opts, :max_queue, @max_queue),
      receiver_stop_ms: Keyword.get(opts, :receiver_stop_ms, @receiver_stop_ms),
      health_check_ms: Keyword.get(opts, :health_check_ms, @health_check_ms),
      health: nil,
      health_failure: nil,
      quiet: false,
      ready: false,
      last_error: nil,
      retry_ms: retry_ms,
      backoff_ms: retry_ms,
      retry_timer: nil,
      radio_mon: nil,
      lease: nil,
      conn: nil,
      conn_mon: nil,
      rx: nil,
      rx_name: nil,
      discovering: false,
      subscribers: %{},
      dedupe: %{},
      recent_tx: [],
      tx_queue: :queue.new(),
      tx_current: nil,
      last_tx_sn: nil,
      wedge_failures: Keyword.get(opts, :wedge_failures, @wedge_failures),
      wedge_window_ms: Keyword.get(opts, :wedge_window_ms, @wedge_window_ms),
      wedge_retry_ms: wedge_retry_ms,
      max_wedge_retry_ms: Keyword.get(opts, :max_wedge_retry_ms, @max_wedge_retry_ms),
      wedge_backoff_ms: wedge_retry_ms,
      # Controller-fault advertise refusals in a row, and when the run began
      # (monotonic ms).
      adv_failures: 0,
      adv_failure_since: nil,
      wedges: 0,
      wedge_streak: 0,
      recoveries: 0,
      last_wedge_at: nil,
      last_recovery_at: nil,
      # Set by a wedge: the next setup power-cycles the adapter.
      reset_pending: false
    }

    {:ok, state, {:continue, :setup}}
  end

  @impl GenServer
  def handle_continue(:setup, state), do: {:noreply, attempt_setup(state)}

  # ── Setup / retry ────────────────────────────────────────────────────

  defp attempt_setup(state) do
    case setup(state) do
      {:ok, state} ->
        if state.last_error != nil and not state.quiet do
          Logger.info("#{inspect(__MODULE__)}: ready on hci#{state.adapter_index}")
        end

        schedule_health(%{
          state
          | ready: true,
            last_error: nil,
            quiet: false,
            backoff_ms: state.retry_ms
        })

      {:error, reason, state} ->
        state |> teardown() |> not_ready(reason)
    end
  end

  # Each step records what it got in the state it returns (also on error),
  # so teardown/1 can undo exactly that much.
  defp setup(state) do
    with {:ok, state} <- connect(state),
         {:ok, state} <- check_adapter(state),
         {:ok, state} <- reset_controller(state),
         {:ok, state} <- probe_mgmt(state),
         {:ok, state} <- watch_bluez_radio(state),
         {:ok, state} <- acquire(state),
         {:ok, state} <- power_on(state),
         {:ok, state} <- start_discovery(state) do
      start_receiver(state)
    end
  end

  # A runtime loss while ready: undo everything and retry from the start
  # of the backoff (reason is new: last_error is nil while ready).
  # `quiet` leaves the loss (and the recovery after it) unlogged.
  defp lost(state, reason, quiet \\ false)

  defp lost(%{ready: true} = state, reason, quiet),
    do: not_ready(%{teardown(state) | backoff_ms: state.retry_ms}, reason, quiet)

  # Already retrying: the next attempt rebuilds whatever this was.
  defp lost(state, _reason, _quiet), do: state

  defp not_ready(state, reason, quiet \\ false) do
    if reason != state.last_error and not quiet do
      Logger.warning(
        "#{inspect(__MODULE__)}: hci#{state.adapter_index} not ready (#{inspect(reason)}), retrying"
      )
    end

    retry_later(state, reason, quiet)
  end

  defp retry_later(state, reason, quiet) do
    timer = Process.send_after(self(), :retry_setup, state.backoff_ms)

    %{
      state
      | ready: false,
        last_error: reason,
        quiet: quiet,
        retry_timer: timer,
        backoff_ms: min(state.backoff_ms * 2, @max_retry_ms)
    }
  end

  # One pending check at a time, matched by token so a message that was
  # already queued when its timer was cancelled is ignored.
  defp schedule_health(state) do
    state = cancel_health(state)
    token = make_ref()
    timer = Process.send_after(self(), {:health_check, token}, state.health_check_ms)
    %{state | health: {token, timer}}
  end

  defp cancel_health(%{health: {_token, timer}} = state) do
    Process.cancel_timer(timer)
    %{state | health: nil}
  end

  defp cancel_health(state), do: state

  defp check_health(state) do
    if state.receiver.listening?(state.rx_name) do
      with :ok <- check_discovering(state), do: verify_address(state)
    else
      {:error, :receiver_not_listening}
    end
  end

  defp check_discovering(state) do
    body = [@adapter_iface, "Discovering"]

    case state.dbus.call(
           state.conn,
           adapter_path(state),
           @props_iface,
           "Get",
           "ss",
           body,
           @health_call_ms
         ) do
      {:ok, [{_sig, true}]} -> :ok
      {:ok, _other} -> {:error, :not_discovering}
      {:error, reason} -> {:error, {:discovering, reason}}
    end
  end

  # Takes everything setup got back down, except the D-Bus connection and
  # the Bluez.Radio subscription, which are reused by the next attempt.
  # A failed stop_advertising needs nothing more here: releasing the lease
  # removes every instance sent under it.
  defp teardown(state) do
    state = cancel_health(state)
    {_result, state} = stop_current(state)
    state = %{state | tx_queue: :queue.new(), ready: false}
    state = stop_receiver(state)
    state = stop_discovery(state)

    if state.lease != nil, do: state.bluez_radio.release(state.lease)
    %{state | lease: nil}
  end

  defp probe_mgmt(state) do
    case state.mgmt.read_advertising_features(state.adapter_index) do
      {:ok, _features} -> {:ok, state}
      {:error, reason} -> {:error, {:mgmt, reason}, state}
    end
  end

  # Subscribed before acquiring, so a lease end can't slip in between.
  defp watch_bluez_radio(%{radio_mon: nil} = state) do
    case state.bluez_radio.subscribe() do
      {:ok, pid} -> {:ok, %{state | radio_mon: Process.monitor(pid)}}
      {:error, reason} -> {:error, {:bluez_radio, reason}, state}
    end
  end

  defp watch_bluez_radio(state), do: {:ok, state}

  defp acquire(state) do
    case state.bluez_radio.acquire(adapter_index: state.adapter_index) do
      {:ok, lease} -> {:ok, %{state | lease: lease}}
      {:error, reason} -> {:error, {:lease, reason}, state}
    end
  end

  # The connection is bound to this process (rebus closes it when we
  # exit) but not linked, so it is monitored instead.
  defp connect(%{conn: nil} = state) do
    case rebus_connect(state) do
      {:ok, conn} when is_pid(conn) ->
        {:ok, %{state | conn: conn, conn_mon: Process.monitor(conn)}}

      other ->
        {:error, {:dbus_connect, other}, state}
    end
  end

  defp connect(state), do: {:ok, state}

  # Bluez.Rebus.connect/1 exits when its ConnectionSupervisor isn't up.
  defp rebus_connect(state) do
    state.rebus.connect(:system)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp check_adapter(state) do
    case verify_address(state) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp verify_address(%{adapter_address: nil}), do: :ok

  defp verify_address(state) do
    body = [@adapter_iface, "Address"]

    case state.dbus.call(
           state.conn,
           adapter_path(state),
           @props_iface,
           "Get",
           "ss",
           body,
           @health_call_ms
         ) do
      {:ok, [{_sig, address}]} when is_binary(address) ->
        if upcase(address) == state.adapter_address,
          do: :ok,
          else: {:error, {:wrong_adapter, upcase(address)}}

      {:ok, _other} ->
        {:error, {:adapter_address, :unexpected_reply}}

      {:error, reason} ->
        {:error, {:adapter_address, reason}}
    end
  end

  defp upcase(mac) when is_binary(mac), do: String.upcase(mac)
  defp upcase(_mac), do: nil

  # Idempotent: setting Powered on a powered adapter is a no-op. It is not
  # undone on teardown, since the adapter is dedicated to this radio.
  defp power_on(state) do
    case set_powered(state, true) do
      {:ok, _} -> {:ok, state}
      {:error, reason} -> {:error, {:power, reason}, state}
    end
  end

  # After a wedge (see the moduledoc). Runs after the adapter fence, with
  # no lease held, and only until it succeeds once: a later step failing
  # doesn't cycle the adapter again. BlueZ answers a Powered Set only once
  # the kernel has finished closing (or opening) the controller.
  defp reset_controller(%{reset_pending: false} = state), do: {:ok, state}

  defp reset_controller(state) do
    with {:off, {:ok, _}} <- {:off, set_powered(state, false)},
         {:on, {:ok, _}} <- {:on, set_powered(state, true)} do
      Logger.info("#{inspect(__MODULE__)}: power-cycled hci#{state.adapter_index}")

      {:ok,
       %{
         state
         | reset_pending: false,
           recoveries: state.recoveries + 1,
           last_recovery_at: DateTime.utc_now()
       }}
    else
      {:off, {:error, reason}} -> {:error, {:power_cycle, reason}, state}
      {:on, {:error, reason}} -> {:error, {:power, reason}, state}
    end
  end

  defp set_powered(state, on?) do
    body = [@adapter_iface, "Powered", {"b", on?}]
    state.dbus.call(state.conn, adapter_path(state), @props_iface, "Set", "ssv", body)
  end

  defp start_discovery(state) do
    filter = [{"Transport", {"s", "le"}}, {"DuplicateData", {"b", true}}]

    with {:ok, _} <- adapter_call(state, "SetDiscoveryFilter", "a{sv}", [filter]),
         {:ok, _} <- start_discovery_call(state) do
      {:ok, %{state | discovering: true}}
    else
      {:error, reason} -> {:error, {:discovery, reason}, state}
    end
  end

  defp start_discovery_call(state) do
    case adapter_call(state, "StartDiscovery", "", []) do
      # Already discovering for this connection: goal reached.
      {:error, "org.bluez.Error.InProgress"} -> {:ok, []}
      other -> other
    end
  end

  defp stop_discovery(%{discovering: true, conn: conn} = state) when conn != nil do
    _ = adapter_call(state, "StopDiscovery", "", [])
    %{state | discovering: false}
  end

  defp stop_discovery(state), do: %{state | discovering: false}

  defp adapter_call(state, member, signature, body) do
    state.dbus.call(state.conn, adapter_path(state), @adapter_iface, member, signature, body)
  end

  defp adapter_path(state), do: "/org/bluez/hci#{state.adapter_index}"

  defp start_receiver(state) do
    radio = self()

    on_report = fn report ->
      for frame <- Carrier.frames(report.data) do
        GenServer.cast(
          radio,
          {:report, report.address, frame, report.rssi}
        )
      end
    end

    name = Module.concat(__MODULE__, "Rx#{state.adapter_index}")

    # `{:already_started, pid}` is not ours (not linked, not stopped on
    # teardown): an error like any other, retried.
    case state.receiver.start_link(
           name: name,
           adapter_index: state.adapter_index,
           on_report: on_report
         ) do
      {:ok, pid} -> {:ok, %{state | rx: pid, rx_name: name}}
      {:error, reason} -> {:error, {:receiver, reason}, state}
    end
  end

  # Unlinked first, so stopping it doesn't come back as an {:EXIT, ...}.
  # One that won't stop in time is killed: left alive it would keep the
  # registered Rx name and fail every later setup with already_started.
  defp stop_receiver(%{rx: rx} = state) when is_pid(rx) do
    Process.unlink(rx)

    try do
      GenServer.stop(rx, :normal, state.receiver_stop_ms)
    catch
      :exit, _reason -> kill_receiver(rx)
    end

    %{state | rx: nil, rx_name: nil}
  end

  defp stop_receiver(state), do: %{state | rx: nil, rx_name: nil}

  defp kill_receiver(rx) do
    ref = Process.monitor(rx)
    Process.exit(rx, :kill)

    receive do
      {:DOWN, ^ref, :process, ^rx, _reason} -> :ok
    after
      1_000 -> :ok
    end

    Process.demonitor(ref, [:flush])
  end

  # ── TX ───────────────────────────────────────────────────────────────

  @impl GenServer
  def handle_call({:send_frame, _frame, _ms, _class, _key}, _from, %{ready: false} = state),
    do: {:reply, {:error, :not_ready}, state}

  def handle_call({:send_frame, frame, duration_ms, class, key}, _from, state) do
    job = %{
      frame: frame,
      duration_ms: duration_ms,
      class: class,
      key: if(class == :normal, do: key),
      norm: P2.normalize(frame)
    }

    queue = drop_superseded(state.tx_queue, job)
    state = %{state | tx_queue: queue}

    cond do
      # Nothing on air (so nothing queued either): start it now, so a
      # refusal reaches the caller.
      state.tx_current == nil and :queue.is_empty(queue) ->
        case start_job(state, job) do
          {:ok, state} -> {:reply, :ok, state}
          {:error, reason, state} -> {:reply, {:error, reason}, state}
        end

      :queue.len(queue) >= state.max_queue ->
        {:reply, {:error, :queue_full}, state}

      true ->
        {:reply, :ok, maybe_start_next(%{state | tx_queue: :queue.in(job, queue)})}
    end
  end

  def handle_call(:stop_tx, _from, state) do
    {:reply, :ok, stop_and_continue(%{state | tx_queue: :queue.new()})}
  end

  def handle_call(:clear_tx, _from, state) do
    {:reply, :ok, stop_and_continue(%{state | tx_queue: :queue.new(), last_tx_sn: nil})}
  end

  def handle_call({:subscribe, pid, filter}, _from, state) do
    mon =
      case state.subscribers do
        %{^pid => {_filter, mon}} -> mon
        _new -> Process.monitor(pid)
      end

    {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, {filter, mon})}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    case Map.pop(state.subscribers, pid) do
      {{_filter, mon}, subscribers} ->
        Process.demonitor(mon, [:flush])
        {:reply, :ok, %{state | subscribers: subscribers}}

      {nil, _subscribers} ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:set_drop_echoes, drop?}, _from, state) do
    {:reply, :ok, %{state | drop_echoes: drop?}}
  end

  def handle_call(:status, _from, state) do
    status = %{
      ready: state.ready,
      last_error: state.last_error,
      adapter_index: state.adapter_index,
      adapter_address: state.adapter_address,
      lease_held: state.lease != nil and state.bluez_radio.valid?(state.lease),
      discovering: state.discovering,
      listening: state.rx_name != nil and state.receiver.listening?(state.rx_name),
      subscribers: map_size(state.subscribers),
      tx:
        case state.tx_current do
          nil -> nil
          %{class: class, instance: instance} -> %{class: class, instance: instance}
        end,
      queued: :queue.len(state.tx_queue),
      last_tx_sn: state.last_tx_sn,
      advertise_failures: state.adv_failures,
      wedges: state.wedges,
      wedge_streak: state.wedge_streak,
      recoveries: state.recoveries,
      last_wedge_at: state.last_wedge_at,
      last_recovery_at: state.last_recovery_at,
      controller_reset_needed: state.wedge_streak >= 2
    }

    {:reply, {:ok, status}, state}
  end

  @impl GenServer
  def handle_cast({:report, address, frame, rssi}, state) do
    {:noreply, fan_out(state, address, frame, rssi)}
  end

  # Matched by a per-advert token, not the Mgmt instance number: Mgmt
  # reuses instance numbers, so a timer message that was already queued
  # when its advert was stopped would otherwise cut a newer advert short.
  @impl GenServer
  def handle_info({:tx_done, token}, %{tx_current: %{token: token}} = state) do
    {:noreply, stop_and_continue(state)}
  end

  def handle_info(:retry_setup, %{ready: false} = state),
    do: {:noreply, attempt_setup(%{state | retry_timer: nil})}

  def handle_info({:health_check, token}, %{ready: true, health: {token, _timer}} = state) do
    state = %{state | health: nil}

    case check_health(state) do
      :ok ->
        {:noreply, schedule_health(%{state | health_failure: nil})}

      {:error, reason} ->
        reason = {:health, reason}
        quiet = reason == state.health_failure
        {:noreply, lost(%{state | health_failure: reason}, reason, quiet)}
    end
  end

  # Bluez.Radio notifies every subscriber of every lease end; only ours
  # matters. Mgmt has already taken its adverts off air.
  def handle_info({:radio_lease_ended, ref}, %{lease: %{ref: ref}} = state) do
    {:noreply, lost(%{state | lease: nil}, :lease_ended)}
  end

  def handle_info({:DOWN, mon, :process, _pid, reason}, %{radio_mon: mon} = state) do
    state = %{state | radio_mon: nil, lease: nil}
    {:noreply, lost(state, {:bluez_radio_down, reason})}
  end

  # BlueZ drops a client's discovery session when its connection closes.
  def handle_info({:DOWN, mon, :process, _pid, reason}, %{conn_mon: mon} = state) do
    state = %{state | conn: nil, conn_mon: nil, discovering: false}
    {:noreply, lost(state, {:dbus_down, reason})}
  end

  def handle_info({:DOWN, mon, :process, pid, _reason}, state) do
    case state.subscribers do
      %{^pid => {_filter, ^mon}} ->
        {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, rx, reason}, %{rx: rx} = state) when is_pid(rx) do
    {:noreply, lost(%{state | rx: nil, rx_name: nil}, {:receiver_exit, reason})}
  end

  # The receiver is the only link we make, and the parent's EXIT never gets
  # here; anything else (an earlier receiver, a failed start_link) is stale.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = teardown(state)
    :ok
  end

  # A :control job drops every queued :normal one; a :normal job with a
  # coalesce key drops the queued job with the same key.
  defp drop_superseded(queue, %{class: :control}),
    do: :queue.filter(&(&1.class != :normal), queue)

  defp drop_superseded(queue, %{key: nil}), do: queue
  defp drop_superseded(queue, %{key: key}), do: :queue.filter(&(&1.key != key), queue)

  defp maybe_start_next(%{tx_current: nil, ready: true} = state) do
    case :queue.out(state.tx_queue) do
      {{:value, job}, queue} ->
        case start_job(%{state | tx_queue: queue}, job) do
          {:ok, state} -> state
          {:error, {:uncertain, _reason}, state} -> state
          {:error, _refused, state} -> maybe_start_next(state)
        end

      {:empty, _queue} ->
        state
    end
  end

  defp maybe_start_next(state), do: state

  defp start_job(state, job) do
    case state.mgmt.advertise(state.lease, Carrier.ad_bytes(job.frame), flags: [:connectable]) do
      {:ok, instance} ->
        token = make_ref()
        timer = Process.send_after(self(), {:tx_done, token}, job.duration_ms)
        current = Map.merge(job, %{instance: instance, timer: timer, token: token})

        state = %{
          state
          | tx_current: current,
            recent_tx: Enum.take([job.norm | state.recent_tx], @recent_tx_max),
            last_tx_sn: frame_sn(job.frame)
        }

        {:ok, advertise_accepted(state)}

      {:error, reason} when reason in @fatal_advertise_errors ->
        {:error, {:uncertain, reason}, lost(state, {:advertise, reason})}

      {:error, reason} when reason in @wedge_advertise_errors ->
        Logger.warning(
          "#{inspect(__MODULE__)}: advertise failed (#{inspect(reason)}), dropping frame"
        )

        {:error, {:advertise, reason}, controller_fault(state, reason)}

      {:error, reason} ->
        Logger.warning(
          "#{inspect(__MODULE__)}: advertise failed (#{inspect(reason)}), dropping frame"
        )

        {:error, {:advertise, reason}, state}
    end
  end

  # P2 header: hdr, source (2), destination (2), then the sequence number.
  defp frame_sn(<<_hdr, _src::binary-2, _dst::binary-2, sn::16-big, _::binary>>), do: sn

  # ── Wedged controller ────────────────────────────────────────────────

  defp advertise_accepted(%{wedge_streak: 0} = state),
    do: %{state | adv_failures: 0, adv_failure_since: nil}

  defp advertise_accepted(state) do
    Logger.info("#{inspect(__MODULE__)}: hci#{state.adapter_index} advertising again")

    %{
      state
      | adv_failures: 0,
        adv_failure_since: nil,
        wedge_streak: 0,
        wedge_backoff_ms: state.wedge_retry_ms
    }
  end

  defp controller_fault(state, reason) do
    now = System.monotonic_time(:millisecond)
    since = state.adv_failure_since || now
    failures = state.adv_failures + 1

    if failures >= state.wedge_failures or now - since > state.wedge_window_ms,
      do: wedged(state, reason, failures),
      else: %{state | adv_failures: failures, adv_failure_since: since}
  end

  # Torn down like any other loss, but retried on the wedge backoff and
  # with a power-cycle (reset_controller/1) in the next setup.
  defp wedged(state, reason, failures) do
    streak = state.wedge_streak + 1
    delay = state.wedge_backoff_ms
    log_wedge(state, reason, failures, streak, delay)

    state = %{
      teardown(state)
      | backoff_ms: delay,
        wedge_backoff_ms: min(delay * 2, state.max_wedge_retry_ms),
        adv_failures: 0,
        adv_failure_since: nil,
        wedges: state.wedges + 1,
        wedge_streak: streak,
        last_wedge_at: DateTime.utc_now(),
        reset_pending: true
    }

    retry_later(state, {:controller_wedged, reason}, false)
  end

  defp log_wedge(state, reason, failures, 1, delay) do
    Logger.error(
      "#{inspect(__MODULE__)}: hci#{state.adapter_index} controller wedged " <>
        "(#{failures} advertises failed with #{inspect(reason)}); " <>
        "power-cycling it in #{delay} ms"
    )
  end

  defp log_wedge(state, reason, _failures, 2, delay) do
    Logger.error(
      "#{inspect(__MODULE__)}: hci#{state.adapter_index} controller still wedged " <>
        "(#{inspect(reason)}) after a power-cycle; its transport needs a reset " <>
        "(USB reset or btusb rebind). Power-cycling again in #{delay} ms"
    )
  end

  defp log_wedge(state, reason, _failures, streak, delay) do
    Logger.warning(
      "#{inspect(__MODULE__)}: hci#{state.adapter_index} controller wedged " <>
        "#{streak} times in a row (#{inspect(reason)}); power-cycling again in #{delay} ms"
    )
  end

  # Takes the current advert off air and starts the next; an advert that
  # won't come off air means the instance (and the lease) can't be trusted,
  # so the radio re-runs setup, whose teardown releases the lease.
  defp stop_and_continue(state) do
    case stop_current(state) do
      {:ok, state} -> maybe_start_next(state)
      {{:error, reason}, state} -> lost(state, {:stop_advertising, reason})
    end
  end

  defp stop_current(%{tx_current: nil} = state), do: {:ok, state}

  defp stop_current(%{tx_current: current} = state) do
    Process.cancel_timer(current.timer)
    state = %{state | tx_current: nil}

    # Without a lease (it ended) Mgmt has already removed the instance.
    case state.lease && state.mgmt.stop_advertising(state.lease, current.instance) do
      nil -> {:ok, state}
      :ok -> {:ok, state}
      {:error, :unknown_instance} -> {:ok, state}
      {:error, _reason} = error -> {error, state}
    end
  end

  # ── RX ───────────────────────────────────────────────────────────────

  defp fan_out(state, address, frame, rssi) do
    norm = P2.normalize(frame)
    now = System.monotonic_time(:millisecond)
    key = {address, norm}

    cond do
      state.drop_echoes and norm in state.recent_tx ->
        state

      seen_recently?(state.dedupe, key, now) ->
        state

      true ->
        report = %{mac: mac_string(address), address: address, frame: frame, rssi: rssi}

        for {pid, {filter, _mon}} <- state.subscribers, wants?(filter, report, frame) do
          Kernel.send(pid, {:tuya_report, report})
        end

        %{state | dedupe: remember(state.dedupe, key, now)}
    end
  end

  defp wants?(:all, _report, _frame), do: true
  defp wants?(:unpaired, _report, frame), do: match?({:ok, _}, P2.parse_unpaired(frame))
  defp wants?({:mac, mac}, report, _frame), do: report.mac == mac

  defp seen_recently?(dedupe, key, now) do
    case dedupe do
      %{^key => seen_ms} -> now - seen_ms < @dedupe_ms
      _new -> false
    end
  end

  # Bounded: past @dedupe_max entries expired ones are pruned, and if a
  # flood of distinct frames leaves it still full it starts over (a missed
  # dedupe only passes on a duplicate).
  defp remember(dedupe, key, now) do
    dedupe = Map.put(dedupe, key, now)

    if map_size(dedupe) > @dedupe_max do
      pruned = Map.filter(dedupe, fn {_key, seen_ms} -> now - seen_ms < @dedupe_ms end)
      if map_size(pruned) > div(@dedupe_max, 2), do: %{key => now}, else: pruned
    else
      dedupe
    end
  end
end
