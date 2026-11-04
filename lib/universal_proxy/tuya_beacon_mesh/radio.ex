defmodule UniversalProxy.TuyaBeaconMesh.Radio do
  @moduledoc """
  The board's single P2 radio: drives one adapter through a transport,
  serialises transmissions, and fans received frames out to subscribers.

  The controller is reached through a
  `UniversalProxy.TuyaBeaconMesh.Radio.Transport` (`:transport` option).
  The default is
  `UniversalProxy.TuyaBeaconMesh.Radio.Transport.UserChannel` (an
  exclusive HCI user channel), falling back to
  `UniversalProxy.TuyaBeaconMesh.Radio.Transport.Bluez` (`bluetoothd`
  discovery, a raw HCI advert receiver and a `Bluez.Mgmt` advertising
  lease); their moduledocs have the setup steps and the adapter fence.
  This module keeps everything that doesn't depend on how the controller
  is driven: the TX queue and each frame's time on air, `last_tx_sn`,
  duplicate and echo filtering, the fan-out, setup retries, the
  health-check timer, wedge detection and the transport fallback.

  When setup fails, the radio stays up but not ready: whatever the attempt
  got is undone (the transport's `teardown`), the reason is logged once
  (`status/1`'s `:last_error`), and setup is retried after 2 s, doubling up
  to 30 s. The same happens at runtime when the transport reports a loss
  (for the Bluez transport: the lease ends, `Bluez.Radio` or the D-Bus
  connection goes down, the receiver exits, `Bluez.Mgmt` stops accepting
  sends) or a health check fails. While not ready, `send_frame/3` returns
  `{:error, :not_ready}` (queued frames are dropped); subscriptions are
  kept and deliver again once ready.

  Some losses send no message at all (for the Bluez transport, an adapter
  removed or a `bluetoothd` restart ends discovery while every process
  survives). So while ready, every `:health_check_ms` (default 15 s) the
  radio runs the transport's health check and re-runs setup when it fails.
  A failure that comes back right after the re-setup it caused is logged
  once, until a check passes.

  On stop it takes any advert off air and the transport releases the
  controller.

  ## Transport fallback

  `:transport` is a module or a list of them, in order of preference. The
  Radio starts with the first one whose `init/1` accepts the options (the
  user channel needs `:adapter_address`). It moves to the next one, for
  the rest of its life, when a setup fails in a way the transport calls
  permanent (`c:UniversalProxy.TuyaBeaconMesh.Radio.Transport.fallback?/1`;
  for the user channel, a failure after the bind or a control socket that
  can't be opened) while it was never ready, or after
  `:fallback_failures` (default 5) failures in a row that are permanent
  or transient (for the user channel, the controller busy: MGMT Busy on
  the power-off, or the bind refused, while `bluetoothd` is still
  configuring a just-added adapter). The adapter being absent, or another
  adapter under its index, never moves it and breaks a run. `status/1` shows the transport in use (`:transport`) and the
  failure that caused the move (`:fallback_reason`, `nil` while on the
  first choice).

  From the move until the new transport is first ready, but for at most
  `:handoff_ms` (default 10 s), `status/1`'s `:transport_handoff` is
  true: the controller is between owners (the user channel just released
  it, `bluetoothd` is taking it back), so a host shouldn't read its
  absence as the adapter leaving.

  With `:fallback_memory_ms` (default 0, off) the move outlives this
  process: a Radio started for the same `:adapter_address` within that
  time, with the same `:transport` chain, starts on the transport it
  moved to last (logged, with the same `:fallback_reason`), so a host
  that restarts the Radio can't loop through the failing transports
  again.

  ## Wedged controller

  A controller can wedge with every process healthy and every check above
  passing, yet every advertise refused by the controller (seen on an
  RTL8761B after hours of uptime: *LE Set Extended Advertising Enable*
  failing with `EMLINK`, which MGMT reports as `:failed`). Only
  advertising shows it, so the radio counts advertise refusals the
  transport classes as a controller fault (Bluez: MGMT `:failed` and
  `:timeout`), and the faults a transport reports on its own. Per-frame
  refusals (`:busy`, `:rotation_busy`, `:rejected`, `:invalid_params`, …)
  and the uncertain ones neither count nor reset the count; an accepted
  advertise resets it. After `:wedge_failures` (default 3) in a row, or a
  run of them spanning more than `:wedge_window_ms` (default 30 s), the
  controller is declared wedged: `:last_error` becomes
  `{:controller_wedged, reason}`, and the radio tears down and goes not
  ready like any other loss, so sends get `{:error, :not_ready}` until it
  is back.

  Recovery is the next setup, after `:wedge_retry_ms` (default 5 s,
  doubling per wedge up to `:max_wedge_retry_ms`, 60 s; reset by an
  accepted advertise), with a controller reset added (user channel: HCI
  Reset; Bluez: the adapter is power-cycled right after the adapter fence
  and before the lease is taken). A wedge that comes back before any
  advertise was accepted (`:wedge_streak` 2 or more) is logged at error
  level and sets `:controller_reset_needed`, and the radio keeps
  resetting on the backoff above. Only resetting the controller's
  transport (for a USB dongle, a port reset or `btusb` unbind/bind) is
  left, and that is the host's call.

  Hosts reading `status/1`: `:controller_reset_needed` means "reset the
  controller's transport", and stays set until an advertise is accepted
  again; `:wedges` / `:recoveries` count wedges detected and controller
  resets done since start, and `:last_wedge_at` / `:last_recovery_at` are
  their UTC times. While recovering, `ready` is false with `last_error`
  `{:controller_wedged, _}`: show the radio as down, not the bulbs. A
  frame refused while the controller was failing (before the wedge was
  declared) is `{:error, {:advertise, reason}}` and was not transmitted;
  presence logic should treat it, like `:not_ready`, as no verdict.

  ## TX

  `send_frame/3` queues a 26-byte frame for `duration_ms` of advertising;
  the radio's own timer takes it off air. One advert is on air at a time,
  in the order sent, so sequence numbers go on air in the order they were
  handed out. Frames are sent with the app's queue classes
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
  """

  use GenServer

  require Logger

  alias UniversalProxy.TuyaBeaconMesh.{Carrier, P2}
  alias UniversalProxy.TuyaBeaconMesh.Radio.Transport

  @dedupe_ms 2_000
  @dedupe_max 1_024
  @recent_tx_max 32
  @retry_ms 2_000
  @max_retry_ms 30_000

  @max_queue 8
  @health_check_ms 15_000

  @wedge_failures 3
  @wedge_window_ms 30_000
  @wedge_retry_ms 5_000
  @max_wedge_retry_ms 60_000

  @transports [Transport.UserChannel, Transport.Bluez]
  @fallback_failures 5
  @handoff_ms 10_000

  # ── Client API ─────────────────────────────────────────────────────────

  @doc """
  Starts the radio for one adapter.

  Options: `:adapter_index` (default 0), `:adapter_address` (the
  adapter's expected MAC, any case; `nil`, the default, skips the check),
  `:name` (default
  `#{inspect(__MODULE__)}`), `:drop_echoes` (default `true`),
  `:retry_ms` (first setup retry delay, default #{@retry_ms}; doubles up
  to #{@max_retry_ms}), `:max_queue` (default #{@max_queue}),
  `:health_check_ms` (interval of the health check while ready, default
  #{@health_check_ms}), `:wedge_failures` (default #{@wedge_failures}),
  `:wedge_window_ms` (default #{@wedge_window_ms}), `:wedge_retry_ms`
  (default #{@wedge_retry_ms}) and `:max_wedge_retry_ms` (default
  #{@max_wedge_retry_ms}) (see "Wedged controller"), `:transport` (a
  module or a list, default `[Transport.UserChannel, Transport.Bluez]`)
  `:fallback_failures` (default #{@fallback_failures}), `:handoff_ms`
  (default #{@handoff_ms}) and `:fallback_memory_ms` (default 0) (see
  "Transport fallback"). The options are passed on to the transport's `init/1` too
  (the user channel's `:hci_user` and `:hci_user_opts`; the Bluez
  transport's `:bluez_radio`, `:mgmt`, `:rebus`, `:dbus`, `:receiver` and
  `:receiver_stop_ms`).

  Every client function takes `server:` (default `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # Teardown can take several seconds when BlueZ is slow; a kill is still
  # safe (Bluez.Radio ends the lease, the D-Bus connection closes, the
  # user channel's process closes its socket when this one exits).
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
  moduledoc; refused before reaching the transport), `{:error,
  :queue_full}`, `{:error, {:advertise, reason}}` when the adapter
  refused it (a controller fault — Bluez: `:failed` or `:timeout` —
  counts towards declaring the controller wedged, see the moduledoc),
  `{:error, :not_running}` when no radio process exists,
  `{:error, :bad_frame}` / `{:error, :bad_class}`. Not known either way:
  `{:error, :timeout}`, `{:error, :radio_exited}` (the radio died during
  the call), and `{:error, {:uncertain, reason}}` when the path to the
  controller went away during the advertise (Bluez: `Bluez.Mgmt` or the
  lease, `reason` `:not_running`, `:lease_expired` or
  `:not_lease_holder`); the radio then re-runs setup as for any other
  loss.
  """
  @spec send_frame(binary(), non_neg_integer(), keyword()) ::
          :ok
          | {:error,
             :not_running
             | :not_ready
             | :queue_full
             | {:advertise, term()}
             | {:uncertain, term()}
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
  healthy), `:recoveries` (controller resets done), `:last_wedge_at` /
  `:last_recovery_at` (`DateTime` in UTC, or `nil`), and
  `:controller_reset_needed` (a controller reset didn't clear the wedge:
  the host should reset the controller's transport).

  Transport (see "Transport fallback"): `:transport` (`:user_channel` or
  `:bluez`, from the transport), `:fallback_reason`,
  `:transport_handoff`, and whatever else
  the transport reports (the user channel: `:hci_index`, `:controller`).

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
    # Trapping exits turns a crash of anything the transport links (the
    # Bluez advert receiver) into an {:EXIT, pid, _} the transport answers
    # with a loss, instead of taking this process (and its subscriptions
    # and queue) down with it. It also makes a supervisor shutdown run
    # terminate/2, so the controller is released explicitly; gen_server
    # still honours the parent's EXIT itself before handle_info sees it.
    Process.flag(:trap_exit, true)
    retry_ms = Keyword.get(opts, :retry_ms, @retry_ms)
    wedge_retry_ms = Keyword.get(opts, :wedge_retry_ms, @wedge_retry_ms)
    adapter_index = Keyword.get(opts, :adapter_index, 0)
    adapter_address = opts |> Keyword.get(:adapter_address) |> upcase()
    chain = opts |> Keyword.get(:transport, @transports) |> List.wrap()
    memory_ms = Keyword.get(opts, :fallback_memory_ms, 0)

    {transports, remembered} =
      remembered_fallback(chain, adapter_address, adapter_index, memory_ms)

    transport_opts =
      Keyword.merge(opts, adapter_index: adapter_index, adapter_address: adapter_address)

    case init_transport(transports, transport_opts, adapter_index, remembered) do
      {:ok, transport, tstate, fallbacks, fallback_reason} ->
        state = %{
          adapter_index: adapter_index,
          adapter_address: adapter_address,
          transport: transport,
          tstate: tstate,
          transport_opts: transport_opts,
          # The configured transports, in order (the fallback memory's key).
          transport_chain: chain,
          # Transports still to fall back to, and why the Radio left the
          # first choice (nil while on it).
          fallbacks: fallbacks,
          fallback_reason: fallback_reason,
          fallback_failures: Keyword.get(opts, :fallback_failures, @fallback_failures),
          fallback_memory_ms: memory_ms,
          handoff_ms: Keyword.get(opts, :handoff_ms, @handoff_ms),
          # When the last move to another transport happened (monotonic ms).
          fallback_at: nil,
          # Since the current transport was last ready: setup failures it
          # calls permanent, and whether it was ever ready.
          setup_failures: 0,
          was_ready: false,
          drop_echoes: Keyword.get(opts, :drop_echoes, true),
          max_queue: Keyword.get(opts, :max_queue, @max_queue),
          health_check_ms: Keyword.get(opts, :health_check_ms, @health_check_ms),
          health: nil,
          health_failure: nil,
          quiet: false,
          ready: false,
          last_error: nil,
          retry_ms: retry_ms,
          backoff_ms: retry_ms,
          retry_timer: nil,
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
          # Controller-fault advertise refusals in a row, and when the run
          # began (monotonic ms).
          adv_failures: 0,
          adv_failure_since: nil,
          wedges: 0,
          wedge_streak: 0,
          recoveries: 0,
          last_wedge_at: nil,
          last_recovery_at: nil,
          # Set by a wedge: the next setup resets the controller.
          reset_pending: false
        }

        {:ok, state, {:continue, :setup}}

      {:error, reason} ->
        {:stop, {:transport_init, reason}}
    end
  end

  # The first transport whose init accepts the options; a refusal by the
  # last one stops the start.
  defp init_transport([transport | rest], opts, index, fallback_reason) do
    case transport.init(opts) do
      {:ok, tstate} ->
        {:ok, transport, tstate, rest, fallback_reason}

      {:error, reason} when rest != [] ->
        Logger.warning(
          "#{inspect(__MODULE__)}: hci#{index} can't use #{transport_name(transport)} " <>
            "(#{inspect(reason)}); using #{transport_name(hd(rest))}"
        )

        init_transport(rest, opts, index, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp transport_name(module), do: module |> Module.split() |> List.last()

  defp memory_key(address), do: {__MODULE__, :fallback, address}

  # Where an earlier Radio for this address, with the same chain, ended
  # up within `memory_ms`: start there (a position in the chain, so a
  # second fallback is resumed too).
  defp remembered_fallback(chain, address, index, memory_ms)
       when is_binary(address) and memory_ms > 0 do
    with {at, ^chain, position, reason} when position in 1..(length(chain) - 1)//1 <-
           :persistent_term.get(memory_key(address), nil),
         age when age < memory_ms <- System.monotonic_time(:millisecond) - at do
      resumed = Enum.drop(chain, position)

      Logger.warning(
        "#{inspect(__MODULE__)}: hci#{index} fell back to #{transport_name(hd(resumed))} " <>
          "#{div(age, 1_000)} s ago (#{inspect(reason)}); starting on it"
      )

      {resumed, reason}
    else
      _none_or_stale -> {chain, nil}
    end
  end

  defp remembered_fallback(chain, _address, _index, _memory_ms), do: {chain, nil}

  # The transport now in use, as its position in the chain.
  defp remember_fallback(%{fallback_memory_ms: ms, adapter_address: address} = state, reason)
       when ms > 0 and is_binary(address) do
    position = length(state.transport_chain) - length(state.fallbacks) - 1
    entry = {System.monotonic_time(:millisecond), state.transport_chain, position, reason}
    :persistent_term.put(memory_key(address), entry)
  end

  defp remember_fallback(_state, _reason), do: :ok

  defp handoff?(%{fallback_at: nil}), do: false

  defp handoff?(state),
    do:
      not state.was_ready and
        System.monotonic_time(:millisecond) - state.fallback_at < state.handoff_ms

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
            backoff_ms: state.retry_ms,
            setup_failures: 0,
            was_ready: true
        })

      {:error, reason, state} ->
        state |> teardown() |> setup_failed(reason)
    end
  end

  # A failure the transport calls permanent moves to the next transport at
  # once before it was ever ready; otherwise a run of permanent or
  # transient ones does. Any other failure (the adapter absent) breaks the
  # run.
  defp setup_failed(state, reason) do
    case state.fallbacks != [] and fallback_class(state.transport, reason) do
      class when class in [true, :transient] ->
        failures = state.setup_failures + 1
        state = %{state | setup_failures: failures}

        if (class == true and not state.was_ready) or failures >= state.fallback_failures,
          do: fall_back(state, reason),
          else: not_ready(state, reason)

      _other ->
        not_ready(%{state | setup_failures: 0}, reason)
    end
  end

  defp fallback_class(transport, reason) do
    if Code.ensure_loaded?(transport) and function_exported?(transport, :fallback?, 1),
      do: transport.fallback?(reason),
      else: false
  end

  # The next transport starts after the usual first retry delay, which
  # also gives bluetoothd time to take back a controller the user channel
  # released. One whose init refuses is skipped.
  defp fall_back(%{fallbacks: [next | rest]} = state, reason) do
    case next.init(state.transport_opts) do
      {:ok, tstate} ->
        Logger.warning(
          "#{inspect(__MODULE__)}: hci#{state.adapter_index} #{transport_name(state.transport)} " <>
            "failed (#{inspect(reason)}); falling back to #{transport_name(next)}"
        )

        :ok = state.transport.terminate(:fallback, state.tstate)

        state = %{
          state
          | transport: next,
            tstate: tstate,
            fallbacks: rest,
            fallback_reason: reason,
            fallback_at: System.monotonic_time(:millisecond),
            setup_failures: 0,
            was_ready: false,
            backoff_ms: state.retry_ms
        }

        remember_fallback(state, reason)
        retry_later(state, reason, false)

      {:error, init_reason} ->
        Logger.warning(
          "#{inspect(__MODULE__)}: hci#{state.adapter_index} can't use " <>
            "#{transport_name(next)} (#{inspect(init_reason)})"
        )

        setup_failed(%{state | fallbacks: rest}, reason)
    end
  end

  # The transport's state records what the attempt got (also on error), so
  # teardown/1 can undo exactly that much.
  defp setup(state) do
    case state.transport.setup(state.tstate, state.reset_pending) do
      {:ok, tstate, events} ->
        {:ok, Enum.reduce(events, %{state | tstate: tstate}, &setup_event/2)}

      {:error, reason, tstate, events} ->
        {:error, reason, Enum.reduce(events, %{state | tstate: tstate}, &setup_event/2)}
    end
  end

  # A reset that went through isn't asked for again, even when a later
  # setup step failed.
  defp setup_event({:controller_reset, how}, state) do
    Logger.info("#{inspect(__MODULE__)}: #{reset_text(how)} hci#{state.adapter_index}")

    %{
      state
      | reset_pending: false,
        recoveries: state.recoveries + 1,
        last_recovery_at: DateTime.utc_now()
    }
  end

  defp reset_text(:power_cycle), do: "power-cycled"
  defp reset_text(:hci_reset), do: "reset"
  defp reset_text(:rebind), do: "re-bound and reset"
  defp reset_text(how), do: "reset (#{inspect(how)})"

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

  # Takes everything setup got back down. A failed stop_transmit needs
  # nothing more here: the transport's teardown releases the controller.
  defp teardown(state) do
    state = cancel_health(state)
    {_result, state} = stop_current(state)
    state = %{state | tx_queue: :queue.new(), ready: false}
    %{state | tstate: state.transport.teardown(state.tstate)}
  end

  defp upcase(mac) when is_binary(mac), do: String.upcase(mac)
  defp upcase(_mac), do: nil

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
      subscribers: map_size(state.subscribers),
      tx:
        case state.tx_current do
          nil -> nil
          %{class: class, instance: instance} -> %{class: class, instance: instance}
        end,
      queued: :queue.len(state.tx_queue),
      fallback_reason: state.fallback_reason,
      transport_handoff: handoff?(state),
      last_tx_sn: state.last_tx_sn,
      advertise_failures: state.adv_failures,
      wedges: state.wedges,
      wedge_streak: state.wedge_streak,
      recoveries: state.recoveries,
      last_wedge_at: state.last_wedge_at,
      last_recovery_at: state.last_recovery_at,
      controller_reset_needed: state.wedge_streak >= 2
    }

    {:reply, {:ok, Map.merge(state.transport.status(state.tstate), status)}, state}
  end

  # Matched by a per-advert token, not the transport's instance: Mgmt
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

    case state.transport.health_check(state.tstate) do
      :ok ->
        {:noreply, schedule_health(%{state | health_failure: nil})}

      {:error, reason} ->
        reason = {:health, reason}
        quiet = reason == state.health_failure
        {:noreply, lost(%{state | health_failure: reason}, reason, quiet)}
    end
  end

  def handle_info(msg, state) do
    case state.transport.handle_info(msg, state.tstate) do
      {:ok, events, tstate} ->
        {:noreply, Enum.reduce(events, %{state | tstate: tstate}, &transport_event/2)}

      :unhandled ->
        {:noreply, handle_other(msg, state)}
    end
  end

  @impl GenServer
  def terminate(reason, state) do
    state = cancel_health(state)
    {_result, state} = stop_current(state)
    state.transport.terminate(reason, state.tstate)
  end

  defp handle_other({:DOWN, mon, :process, pid, _reason}, state) do
    case state.subscribers do
      %{^pid => {_filter, ^mon}} -> %{state | subscribers: Map.delete(state.subscribers, pid)}
      _other -> state
    end
  end

  # A stale timer, an earlier link's {:EXIT, ...} (the parent's EXIT never
  # gets here), or anything else not ours.
  defp handle_other(_msg, state), do: state

  defp transport_event({:report, address, frame, rssi}, state),
    do: fan_out(state, address, frame, rssi)

  defp transport_event({:lost, reason}, state), do: lost(state, reason)

  defp transport_event({:fault, reason}, %{ready: true} = state) do
    Logger.warning("#{inspect(__MODULE__)}: controller fault (#{inspect(reason)})")
    controller_fault(state, reason)
  end

  # Not ready: the next setup starts the controller over anyway.
  defp transport_event({:fault, _reason}, state), do: state

  # A transport reports resets from setup; one outside it counts the same.
  defp transport_event({:controller_reset, _how} = event, state), do: setup_event(event, state)

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
    case state.transport.transmit(state.tstate, Carrier.ad_bytes(job.frame)) do
      {:ok, instance, tstate} ->
        token = make_ref()
        timer = Process.send_after(self(), {:tx_done, token}, job.duration_ms)
        current = Map.merge(job, %{instance: instance, timer: timer, token: token})

        state = %{
          state
          | tstate: tstate,
            tx_current: current,
            recent_tx: Enum.take([job.norm | state.recent_tx], @recent_tx_max),
            last_tx_sn: frame_sn(job.frame)
        }

        {:ok, advertise_accepted(state)}

      # The path to the controller is gone, not just this frame: re-run
      # setup rather than keep sending.
      {:error, {:uncertain, reason}, tstate} ->
        {:error, {:uncertain, reason}, lost(%{state | tstate: tstate}, {:advertise, reason})}

      {:error, {:fault, reason}, tstate} ->
        log_refused(reason)
        {:error, {:advertise, reason}, controller_fault(%{state | tstate: tstate}, reason)}

      {:error, {:refused, reason}, tstate} ->
        log_refused(reason)
        {:error, {:advertise, reason}, %{state | tstate: tstate}}
    end
  end

  defp log_refused(reason) do
    Logger.warning(
      "#{inspect(__MODULE__)}: advertise failed (#{inspect(reason)}), dropping frame"
    )
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
  # with a controller reset in the next setup.
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
        "resetting it in #{delay} ms"
    )
  end

  defp log_wedge(state, reason, _failures, 2, delay) do
    Logger.error(
      "#{inspect(__MODULE__)}: hci#{state.adapter_index} controller still wedged " <>
        "(#{inspect(reason)}) after a controller reset; its transport needs a reset " <>
        "(USB reset or btusb rebind). Resetting it again in #{delay} ms"
    )
  end

  defp log_wedge(state, reason, _failures, streak, delay) do
    Logger.warning(
      "#{inspect(__MODULE__)}: hci#{state.adapter_index} controller wedged " <>
        "#{streak} times in a row (#{inspect(reason)}); resetting it again in #{delay} ms"
    )
  end

  # Takes the current advert off air and starts the next; an advert that
  # won't come off air means the transport's state can't be trusted, so
  # the radio re-runs setup, whose teardown releases the controller.
  # A controller fault counts towards a wedge first (which may already
  # tear down); re-running setup is forced either way.
  defp stop_and_continue(state) do
    case stop_current(state) do
      {:ok, state} ->
        maybe_start_next(state)

      {{:error, {:fault, reason}}, state} ->
        Logger.warning(
          "#{inspect(__MODULE__)}: taking an advert off air failed (#{inspect(reason)})"
        )

        state |> controller_fault(reason) |> lost({:stop_advertising, reason})

      {{:error, {_uncertain, reason}}, state} ->
        lost(state, {:stop_advertising, reason})
    end
  end

  defp stop_current(%{tx_current: nil} = state), do: {:ok, state}

  defp stop_current(%{tx_current: current} = state) do
    Process.cancel_timer(current.timer)
    state = %{state | tx_current: nil}

    case state.transport.stop_transmit(state.tstate, current.instance) do
      {:ok, tstate} -> {:ok, %{state | tstate: tstate}}
      {:error, reason, tstate} -> {{:error, reason}, %{state | tstate: tstate}}
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
