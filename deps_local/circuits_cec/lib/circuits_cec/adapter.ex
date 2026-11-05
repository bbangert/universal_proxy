defmodule Circuits.CEC.Adapter do
  @moduledoc """
  One HDMI-CEC adapter (`/dev/cecN`) as a CEC 1.4 playback device.

  The adapter opens the device through a `Circuits.CEC.Transport`, becomes
  its exclusive follower, claims a Playback logical address and then:

    * transmits for callers, with typed results (`transmit/4`,
      `request/5` and the helpers built on them),
    * answers the messages a playback device must answer (below),
    * tracks the physical address, logical address, whether we are the
      active source and whether an audio receiver and a TV are on the bus,
    * runs One Touch Play (`one_touch_play/2`),
    * and tells subscribers (`subscribe/2`) what it receives.

  It never blocks: every request to the device is asynchronous and callers
  wait on deferred replies. Each transmit has a safety deadline, so a call
  always returns even if the kernel never reports a result.

  ## Bring-up

  1. Open the device and read its capabilities.
  2. Set the mode to initiator + exclusive follower. If another process
     (libcec, Kodi, `cec-follower`) is already the exclusive follower
     (`EBUSY`), the kernel sends every received message to it alone, so
     the adapter becomes an initiator only (`info(adapter).follower ==
     :unavailable`): transmits work, but there are no follower duties and
     subscribers see only replies to our own requests. Restart the
     adapter once the other follower is gone.
  3. Claim a Playback logical address (CEC 1.4, no vendor ID, OSD name
     from `:osd_name`, falling back to Unregistered if 4, 8 and 11 are
     taken). A claim that already matches is kept, so restarting the
     adapter causes no bus traffic; a different one is cleared first.

  The kernel claims in the background and gives up for good when a claim
  transmit fails (vc4 times them out while the HDMI CRTC is off): it keeps
  the configuration but no logical address, and only tries again on a
  physical-address change. So while our claim is in place, the physical
  address is valid and no logical address came of it, the adapter clears
  and re-sets the configuration, first after `:reclaim_ms` and then at
  doubling intervals up to `:reclaim_max_ms`. A foreign configuration
  found there is left alone.

  The physical address is never set: the HDMI driver sets it from the
  EDID. When the cable is unplugged (or the sink drops hotplug in
  standby) the kernel drops the logical address, and when the physical
  address returns it claims it again by itself. The adapter only follows
  these changes.

  ## Follower duties

  | Received | Answer |
  |---|---|
  | `<Give Device Power Status>` | `<Report Power Status>` (`:power_status`, default `:on`) |
  | `<Request Active Source>` | `<Active Source>`, if we are the active source |
  | `<Set Stream Path>` to our physical address | become the active source, broadcast `<Active Source>` |
  | `<Active Source>`, `<Routing Change>`, `<Routing Information>`, `<Set Stream Path>` elsewhere | no longer the active source |
  | `<Menu Request>` | `<Menu Status>` (deactivated) |
  | `<Standby>` | no longer the active source; no answer |
  | `<Give Deck Status>`, `<Play>`, `<Deck Control>`, `<User Control Pressed/Released>` | nothing if a subscriber handles them (`subscribe(adapter, handle: [...])`), otherwise `<Feature Abort>` |
  | any other directed request | `<Feature Abort>` (unrecognized opcode, or invalid operand when too short) |

  `<Feature Abort>` and reports are never answered, and neither is
  anything else with a directed answer when it was broadcast or came from
  Unregistered (15), since a directed message to 15 would be a broadcast.
  The two answers that are broadcasts (`<Active Source>` for `<Request
  Active Source>` and `<Set Stream Path>`) go out whoever asked, as
  v4l-utils' `cec-follower` does. The kernel answers `<Get CEC Version>`, `<Give
  Physical Address>`, `<Give OSD Name>`, `<Give Device Vendor ID>`,
  `<Abort>` and `<Give Features>` itself, so the adapter doesn't.

  ## The receiver

  `:receiver_la` (default 5, Audio System) names the audio receiver. The
  adapter polls it after every configure. Calls that target `:receiver`
  go to it while it is present (or not known to be absent), and to the TV
  (logical address 0) once it doesn't answer: a `:receiver` call NACKed
  by the receiver is retried once at the TV.

  ## The TV

  With `:tv_poll` (default `true`) the adapter also polls the TV (logical
  address 0) after every configure, and `poll_tv/1` polls it again on
  demand. `tv` in `t:state/0` is the last conclusive answer: `:present`
  when it acknowledged, `:absent` on a NACK, `:unknown` until then and
  whenever the adapter is unconfigured. A single NACK is no proof (a TV
  still booting, or in deep standby, doesn't answer), so every poll result
  also goes to subscribers as a `{:tv_poll, presence}` event (`:unknown`
  for a bus error) for them to apply their own hysteresis.

  ## Subscribers

  Subscribers receive `{:cec, device, event}`, where `event` is

    * `{:message, %Circuits.CEC.Message{}}` - every message received from
      the bus, including replies to our requests,
    * `{:state, state}` - when `t:state/0` changes,
    * `{:tv_poll, presence}` - the result of each TV poll (see The TV),
    * `{:lost_msgs, count}` - the kernel dropped received messages,
    * `:gone` - the device went away; the adapter stops.

  ## Lifecycle

  The adapter stops `:normal` when the device disappears (`gone`, or
  `ENOENT`/`ENODEV` on open), with `{:shutdown, reason}` for other open
  and mode errors, and with `{:port_exit, status}` (a crash, restarted by
  a `:transient` supervisor) when the helper exits. Closing the device
  keeps the logical-address claim, which is adapter state.

  ## Options

    * `:device` (required) - e.g. `"/dev/cec0"`
    * `:name` - GenServer name
    * `:transport` - `Circuits.CEC.Transport` module (default
      `Circuits.CEC.Transport.Port`), and `:transport_opts` for its `open/2`
    * `:osd_name` - OSD name, truncated to 14 bytes (default `"Circuits.CEC"`)
    * `:power_status` - what `<Report Power Status>` says (default `:on`)
    * `:receiver_la` - logical address of the audio receiver (default 5;
      `nil` sends `:receiver` calls to the TV)
    * `:system_audio_mode` - send `<System Audio Mode Request>` to the
      receiver in One Touch Play (default `false`)
    * `:tv_poll` - poll the TV after every configure (default `true`)
    * `:tx_deadline_ms` - how long past its reply timeout a transmit may
      take before it fails with `:timeout` (default 4100: the kernel's
      2.1 s transmit timeout plus 2 s). Callers of a slower adapter pass a
      matching `:call_timeout`.
    * `:reclaim_ms`, `:reclaim_max_ms` - the first and the longest wait
      before re-claiming a logical address the kernel failed to get
      (default 5 s and 60 s; see Bring-up)
  """

  use GenServer, restart: :transient

  import Bitwise

  require Logger

  alias Circuits.CEC.Adapter.Follower
  alias Circuits.CEC.{Errno, Message, Struct}

  @invalid_pa 0xFFFF
  @tv 0
  @broadcast 15
  @unregistered 15

  @reply_timeout 1_000
  @tx_deadline 4_100
  @otp_wait 10_000
  @reclaim 5_000
  @reclaim_max 60_000
  @max_orphans 16
  @osd_name_max 14

  @mode_exclusive 0x21
  @mode_initiator 0x01
  @claim_flags [:allow_unreg_fallback]

  @type adapter :: GenServer.server()

  @typedoc """
  Where a message goes: a logical address, `:broadcast`, `:receiver`
  (the receiver, or the TV without one), or a logical-address name from
  `Circuits.CEC.Message.logical_address/1` (`:tv`, `:audio_system`, ...).
  """
  @type target :: Message.logical_address() | :broadcast | :receiver | atom()

  @typedoc """
  Why a transmit failed.

  Bus outcomes: `:nack` (nobody acknowledged), `:arb_lost`, `:low_drive`,
  `:error`, `:max_retries`, `:aborted` (e.g. the cable was pulled),
  `:timeout` (no reply in time, or no result before the safety deadline)
  and `:feature_abort` (the device refused the request). Local ones:
  `:not_configured` (no logical address), `:busy` (transmit queue full),
  `:closed` (the device went away), `:einval` (a reply was requested for
  a broadcast or poll), `{:invalid_message, _}`, or any other errno.
  """
  @type error ::
          :nack
          | :arb_lost
          | :low_drive
          | :error
          | :max_retries
          | :aborted
          | :timeout
          | :feature_abort
          | :not_configured
          | :busy
          | :closed
          | :einval
          | :unexpected_reply
          | {:invalid_message, term()}
          | Errno.t()

  @type presence :: :present | :absent | :unknown

  @typedoc "What subscribers get in `{:state, state}` events."
  @type state :: %{
          phys_addr: Message.physical_address(),
          log_addrs: [Message.logical_address()],
          configured?: boolean(),
          active_source?: boolean(),
          receiver: presence(),
          tv: presence()
        }

  @type event ::
          {:message, Message.t()}
          | {:state, state()}
          | {:tv_poll, presence()}
          | {:lost_msgs, non_neg_integer()}
          | :gone

  ## Public API

  @doc "Starts an adapter for `opts[:device]`. See the module docs for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc false
  def child_spec(opts) do
    %{super(opts) | id: {__MODULE__, Keyword.fetch!(opts, :device)}}
  end

  @doc """
  The adapter's state: device, caps, connector, physical and logical
  addresses, `configured?`, claim and follower status, active source,
  receiver, settings and counters.
  """
  @spec info(adapter()) :: map()
  def info(adapter), do: GenServer.call(adapter, :info)

  @doc """
  Subscribes the calling process to `{:cec, device, event}` messages.

  `handle:` lists the opcodes this subscriber acts on, from
  `:give_deck_status`, `:play`, `:deck_control` and
  `:user_control_pressed` (which includes `:user_control_released`), or
  `:user_control_released` on its own. The adapter Feature-Aborts those
  only while no subscriber handles them.
  Subscribing again replaces the list; other opcodes raise `ArgumentError`.
  """
  @spec subscribe(adapter(), keyword()) :: :ok
  def subscribe(adapter, opts \\ []) do
    handles = Keyword.get(opts, :handle, [])

    case handles -- Follower.forwardable() do
      [] -> GenServer.call(adapter, {:subscribe, self(), handles})
      bad -> raise ArgumentError, "can't handle #{inspect(bad)}"
    end
  end

  @doc "Removes the calling process's subscription."
  @spec unsubscribe(adapter()) :: :ok
  def unsubscribe(adapter), do: GenServer.call(adapter, {:unsubscribe, self()})

  @doc """
  Sends a message and waits for the transmit result.

  `body` is a `Circuits.CEC.Message` body. The initiator is our logical
  address. While unconfigured the only allowed transmits are a poll,
  `<Image View On>` and `<Text View On>` to the TV, which go out from
  Unregistered (15).

  Option: `:call_timeout`.
  """
  @spec transmit(adapter(), target(), Message.body(), keyword()) :: :ok | {:error, error()}
  def transmit(adapter, to, body, opts \\ []) do
    call(adapter, {:transmit, to, body, nil, 0}, call_timeout(opts, to, 0, 1))
  end

  @doc """
  Sends a request and waits for the reply with opcode `reply` (a name such
  as `:report_power_status`, or a byte).

  A `<Feature Abort>` for the request gives `{:error, :feature_abort}`.

  Options: `:timeout` (ms to wait for the reply, default 1000) and
  `:call_timeout`.
  """
  @spec request(adapter(), target(), Message.body(), atom() | byte(), keyword()) ::
          {:ok, Message.t()} | {:error, error()}
  def request(adapter, to, body, reply, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @reply_timeout)
    call(adapter, {:transmit, to, body, reply, timeout}, call_timeout(opts, to, timeout, 1))
  end

  @doc "Polls a logical address: `:ok` if a device acknowledges it."
  @spec poll(adapter(), target(), keyword()) :: :ok | {:error, error()}
  def poll(adapter, to, opts \\ []), do: transmit(adapter, to, :poll, opts)

  @doc "Sends `<Image View On>` to the TV."
  @spec image_view_on(adapter(), keyword()) :: :ok | {:error, error()}
  def image_view_on(adapter, opts \\ []), do: transmit(adapter, @tv, :image_view_on, opts)

  @doc """
  Broadcasts `<Active Source>` with our physical address and records that
  we are the active source.
  """
  @spec active_source(adapter(), keyword()) :: :ok | {:error, error()}
  def active_source(adapter, opts \\ []),
    do: call(adapter, :active_source, call_timeout(opts, :broadcast, 0, 1))

  @doc """
  Sends `<Standby>` to `to` (`:broadcast` puts every device in standby).
  """
  @spec standby(adapter(), target(), keyword()) :: :ok | {:error, error()}
  def standby(adapter, to, opts \\ []), do: transmit(adapter, to, :standby, opts)

  @doc "Asks `to` for its power status (`:on`, `:standby`, `:to_on`, `:to_standby`)."
  @spec give_power_status(adapter(), target(), keyword()) ::
          {:ok, atom() | byte()} | {:error, error()}
  def give_power_status(adapter, to, opts \\ []) do
    with {:ok, %Message{body: body}} <-
           request(adapter, to, :give_device_power_status, :report_power_status, opts) do
      case body do
        {:report_power_status, power} -> {:ok, power}
        _other -> {:error, :unexpected_reply}
      end
    end
  end

  @doc """
  Asks `to` (default `:receiver`) for its volume (0..100, or `:unknown`)
  and mute state.
  """
  @spec give_audio_status(adapter(), target(), keyword()) ::
          {:ok, %{volume: 0..127 | :unknown, muted: boolean()}} | {:error, error()}
  def give_audio_status(adapter, to \\ :receiver, opts \\ []) do
    with {:ok, %Message{body: body}} <-
           request(adapter, to, :give_audio_status, :report_audio_status, opts) do
      case body do
        {:report_audio_status, muted, volume} -> {:ok, %{volume: volume, muted: muted}}
        _other -> {:error, :unexpected_reply}
      end
    end
  end

  @doc """
  Presses and releases a remote-control key on `to` (`:volume_up`,
  `:mute`, `:power_on_function`, ... or a UI command byte).

  `<User Control Released>` goes out only after the press was
  acknowledged.
  """
  @spec user_control(adapter(), target(), atom() | byte(), keyword()) ::
          :ok | {:error, error()}
  def user_control(adapter, to, key, opts \\ []) do
    call(adapter, {:user_control, to, key}, call_timeout(opts, to, 0, 2))
  end

  @doc """
  One Touch Play: wake the TV (and with it the receiver) and switch it to
  our input.

  Configured: `<Image View On>` to the TV, then `<Active Source>`. Without
  a physical address (a sink that dropped hotplug in standby), only
  `<Image View On>` from Unregistered to the TV is possible, so the
  adapter sends that, waits to be configured and then sends `<Active
  Source>`. With `:system_audio_mode` (default: the adapter's option) it
  then sends `<System Audio Mode Request>` to the receiver. If hotplug
  drops while `<Image View On>` is out, it waits for the address again.
  `:wait_ms` (default 10 s) bounds all of the run's waiting together.

  Returns `:ok` once `<Active Source>` went out, or the error that stopped
  it (`:not_configured` if the wait ran out). Concurrent calls share one
  run.
  """
  @spec one_touch_play(adapter(), keyword()) :: :ok | {:error, error()}
  def one_touch_play(adapter, opts \\ []) do
    wait = Keyword.get(opts, :wait_ms, @otp_wait)
    timeout = Keyword.get(opts, :call_timeout, wait + 4 * (@tx_deadline + @reply_timeout))
    call(adapter, {:one_touch_play, Keyword.take(opts, [:wait_ms, :system_audio_mode])}, timeout)
  end

  @doc """
  Polls the TV (logical address 0) once, unless the adapter is
  unconfigured or a TV poll is already out. The result updates `tv` and
  goes to subscribers as `{:tv_poll, presence}`.
  """
  @spec poll_tv(adapter()) :: :ok
  def poll_tv(adapter), do: GenServer.cast(adapter, :poll_tv)

  @doc "The logical address `:receiver` calls go to right now."
  @spec receiver(adapter()) :: Message.logical_address()
  def receiver(adapter), do: GenServer.call(adapter, :receiver)

  defp call(adapter, request, timeout), do: GenServer.call(adapter, request, timeout)

  # Long enough for the adapter's own deadlines to fire first: `count`
  # transmits, twice for a :receiver call that may fall back to the TV.
  defp call_timeout(opts, to, reply_timeout, count) do
    count = if to == :receiver, do: 2 * count, else: count
    Keyword.get(opts, :call_timeout, count * (reply_timeout + @tx_deadline) + 1_000)
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    device = Keyword.fetch!(opts, :device)
    mod = Keyword.get(opts, :transport, Circuits.CEC.Transport.Port)

    case mod.open(device, Keyword.get(opts, :transport_opts, [])) do
      {:ok, transport} -> {:ok, initial_state(device, mod, transport, opts)}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp initial_state(device, mod, transport, opts) do
    %{
      device: device,
      mod: mod,
      transport: transport,
      osd_name: truncate_osd_name(Keyword.get(opts, :osd_name, "Circuits.CEC")),
      power_status: Keyword.get(opts, :power_status, :on),
      receiver_la: Keyword.get(opts, :receiver_la, 5),
      system_audio_mode: Keyword.get(opts, :system_audio_mode, false),
      tx_deadline: Keyword.get(opts, :tx_deadline_ms, @tx_deadline),
      reclaim_first: Keyword.get(opts, :reclaim_ms, @reclaim),
      reclaim_max: Keyword.get(opts, :reclaim_max_ms, @reclaim_max),
      reclaim_delay: Keyword.get(opts, :reclaim_ms, @reclaim),
      reclaim_timer: nil,
      caps: nil,
      connector: nil,
      ready?: false,
      stopping?: false,
      follower: :none,
      claim: :pending,
      phys_addr: @invalid_pa,
      log_addr_mask: 0,
      generation: 0,
      active_source?: false,
      last_standby: nil,
      receiver: :unknown,
      tv: :unknown,
      tv_poll?: Keyword.get(opts, :tv_poll, true),
      tv_inflight: nil,
      tv_repoll?: false,
      reqs: %{},
      txs: %{},
      seqs: %{},
      orphans: [],
      otp: nil,
      subs: %{},
      last_state: nil,
      counters: %{
        tx_errors: 0,
        lost_msgs: 0,
        dropped_events: 0,
        deadline_expired: 0,
        protocol_errors: 0
      }
    }
  end

  @impl GenServer
  def handle_call(:info, _from, state), do: {:reply, info_map(state), state}

  def handle_call(:receiver, _from, state) do
    {la, _fallback?} = receiver_target(state)
    {:reply, la, state}
  end

  def handle_call({:subscribe, pid, handles}, _from, state) do
    sub =
      case state.subs do
        %{^pid => sub} -> sub
        _ -> %{ref: Process.monitor(pid)}
      end

    subs = Map.put(state.subs, pid, Map.put(sub, :handles, MapSet.new(handles)))
    {:reply, :ok, %{state | subs: subs}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    case Map.pop(state.subs, pid) do
      {nil, _subs} ->
        {:reply, :ok, state}

      {sub, subs} ->
        Process.demonitor(sub.ref, [:flush])
        {:reply, :ok, %{state | subs: subs}}
    end
  end

  def handle_call({:transmit, to, body, reply, timeout}, from, state) do
    {:noreply, start_job(state, job(from, to, :send, body, reply, timeout))}
  end

  def handle_call({:user_control, to, key}, from, state) do
    {:noreply, start_job(state, job(from, to, :user_control, key, nil, 0))}
  end

  def handle_call(:active_source, from, state) do
    if Message.valid_pa?(state.phys_addr) do
      job = job(from, :broadcast, :send, {:active_source, state.phys_addr}, nil, 0)
      {:noreply, start_job(state, job)}
    else
      {:reply, {:error, :not_configured}, state}
    end
  end

  def handle_call({:one_touch_play, opts}, from, state) do
    {:noreply, otp_join(state, from, opts)}
  end

  @impl GenServer
  def handle_cast(:poll_tv, state), do: {:noreply, poll_tv_now(state)}

  @impl GenServer
  def handle_info({:tx_deadline, ref}, state) do
    if Map.has_key?(state.txs, ref) do
      Logger.warning("CEC #{state.device}: no transmit result before the deadline")
      state = bump(state, :deadline_expired)
      {:noreply, complete_tx(state, ref, {:error, :timeout})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:otp_timeout, id}, %{otp: %{id: id, stage: :waiting}} = state) do
    {:noreply, otp_finish(state, {:error, :not_configured})}
  end

  def handle_info({:otp_timeout, _id}, state), do: {:noreply, state}

  def handle_info({:reclaim, token}, %{reclaim_timer: {_timer, token}} = state) do
    state = %{state | reclaim_timer: nil}

    if needs_reclaim?(state) do
      delay = min(state.reclaim_delay * 2, state.reclaim_max)
      state = %{state | reclaim_delay: delay}
      {:noreply, state |> send_internal(:g_log, {:g_log, :reclaim}) |> arm_reclaim()}
    else
      {:noreply, arm_reclaim(state)}
    end
  end

  def handle_info({:reclaim, _token}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case state.subs do
      %{^pid => %{ref: ^ref}} -> {:noreply, %{state | subs: Map.delete(state.subs, pid)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(message, state) do
    case state.mod.handle_message(state.transport, message) do
      {:ok, events, transport} ->
        handle_events(events, %{state | transport: transport})

      :unknown ->
        Logger.debug("CEC #{state.device}: unexpected message #{inspect(message)}")
        {:noreply, state}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    state.mod.close(state.transport)
  end

  @impl GenServer
  def format_status(status) do
    Map.update(status, :state, nil, fn
      %{device: _} = state ->
        state
        |> info_map()
        |> Map.merge(%{
          pending_requests: map_size(state.reqs),
          pending_transmits: map_size(state.txs),
          subscribers: map_size(state.subs),
          one_touch_play: state.otp && state.otp.stage
        })

      other ->
        other
    end)
  end

  ## Transport events

  defp handle_events([], state), do: {:noreply, state}

  defp handle_events([event | rest], state) do
    case handle_event(event, state) do
      {:ok, state} -> handle_events(rest, state)
      {:stop, reason, state} -> {:stop, reason, fail_all(%{state | stopping?: true}, :closed)}
    end
  end

  defp handle_event({:ready, caps}, state) do
    caps = Struct.decode_caps(caps)
    state = %{state | caps: caps}
    state = send_internal(state, {:s_mode, @mode_exclusive}, :mode_exclusive)

    state =
      if :connector_info in Struct.flags(:caps, caps.capabilities),
        do: send_internal(state, :g_conn, :g_conn),
        else: state

    {:ok, state}
  end

  defp handle_event({:open_error, errno}, state) when errno in [:enoent, :enodev] do
    Logger.info("CEC #{state.device}: #{errno} on open")
    {:stop, :normal, state}
  end

  defp handle_event({:open_error, errno}, state) do
    Logger.warning("CEC #{state.device}: can't open (#{inspect(errno)})")
    {:stop, {:shutdown, {:open_error, errno}}, state}
  end

  defp handle_event({:reply, id, result}, state) do
    case Map.pop(state.reqs, id) do
      {nil, _reqs} -> {:ok, state}
      {purpose, reqs} -> on_reply(purpose, result, %{state | reqs: reqs})
    end
  end

  defp handle_event({:msg, bin}, state) do
    msg = Struct.decode_msg(bin)

    if msg.sequence == 0,
      do: {:ok, on_received(state, msg)},
      else: {:ok, on_tx_result(state, msg)}
  end

  defp handle_event({:event, bin}, state),
    do: {:ok, on_kernel_event(state, Struct.decode_event(bin))}

  defp handle_event(:gone, state) do
    Logger.info("CEC #{state.device}: device gone")
    notify(state, :gone)
    {:stop, :normal, state}
  end

  defp handle_event({:exit, status}, state) do
    Logger.warning("CEC #{state.device}: helper exited (#{inspect(status)})")
    {:stop, {:port_exit, status}, state}
  end

  defp handle_event({:protocol_error, data}, state) do
    Logger.warning("CEC #{state.device}: malformed frame #{inspect(data, limit: 16)}")
    {:ok, bump(state, :protocol_errors)}
  end

  ## Bring-up replies

  defp on_reply(:mode_exclusive, {:ok, _}, state), do: {:ok, after_mode(state, :exclusive)}

  # A plain follower would get nothing while another filehandle is the
  # exclusive follower, so don't pretend to be one.
  defp on_reply(:mode_exclusive, {:error, :ebusy}, state) do
    Logger.warning(
      "CEC #{state.device}: another process is the exclusive follower; transmitting only"
    )

    {:ok, send_internal(state, {:s_mode, @mode_initiator}, :mode_initiator)}
  end

  defp on_reply(:mode_initiator, {:ok, _}, state), do: {:ok, after_mode(state, :unavailable)}

  defp on_reply(mode, {:error, errno}, state) when mode in [:mode_exclusive, :mode_initiator] do
    Logger.warning("CEC #{state.device}: can't set the follower mode (#{inspect(errno)})")
    {:stop, {:shutdown, {:s_mode, errno}}, state}
  end

  defp on_reply(:g_conn, {:ok, body}, state),
    do: {:ok, %{state | connector: Struct.decode_connector_info(body)}}

  defp on_reply({:g_log, purpose}, {:ok, body}, state) do
    las = Struct.decode_log_addrs(body)
    state = set_addresses(state, state.phys_addr, las.log_addr_mask)

    case purpose do
      :claim -> {:ok, claim(state, las)}
      :reclaim -> {:ok, reclaim(state, las)}
      _other -> {:ok, state}
    end
  end

  defp on_reply(:g_phys, {:ok, body}, state),
    do: {:ok, set_addresses(state, Struct.decode_phys_addr(body), state.log_addr_mask)}

  defp on_reply(:claim_clear, {:ok, _}, state),
    do: {:ok, send_internal(state, {:s_log, claim_struct(state)}, :claim_set)}

  defp on_reply(:claim_set, {:ok, body}, state) do
    las = Struct.decode_log_addrs(body)
    state = %{state | log_addr_mask: las.log_addr_mask}
    {:ok, set_claim(state, :claimed)}
  end

  defp on_reply(step, {:error, errno}, state) when step in [:claim_clear, :claim_set] do
    Logger.warning("CEC #{state.device}: can't claim a logical address (#{inspect(errno)})")
    {:ok, %{state | claim: {:error, errno}, ready?: true}}
  end

  defp on_reply(:reclaim_clear, {:ok, _}, state),
    do: {:ok, send_internal(state, {:s_log, claim_struct(state)}, :reclaim_set)}

  defp on_reply(:reclaim_set, {:ok, body}, state) do
    las = Struct.decode_log_addrs(body)
    {:ok, set_claim(%{state | log_addr_mask: las.log_addr_mask}, :claimed)}
  end

  # EBUSY: the kernel is configuring right now. Either way the claim we
  # had stays in place and the next check tries again.
  defp on_reply(step, {:error, errno}, state) when step in [:reclaim_clear, :reclaim_set] do
    level = if errno == :ebusy, do: :debug, else: :warning
    Logger.log(level, "CEC #{state.device}: re-claim failed (#{inspect(errno)})")
    {:ok, state}
  end

  defp on_reply({:g_log, :claim}, {:error, errno}, state) do
    Logger.warning("CEC #{state.device}: can't read the logical addresses (#{inspect(errno)})")
    {:ok, %{state | claim: {:error, errno}, ready?: true}}
  end

  defp on_reply({:transmit, ref}, result, state), do: {:ok, on_tx_reply(state, ref, result)}

  defp on_reply(purpose, {:error, errno}, state) do
    Logger.debug("CEC #{state.device}: #{inspect(purpose)} failed (#{inspect(errno)})")
    {:ok, state}
  end

  defp after_mode(state, follower) do
    send_internal(%{state | follower: follower}, :g_log, {:g_log, :claim})
  end

  defp claim(state, las) do
    cond do
      our_claim?(state, las) ->
        Logger.debug("CEC #{state.device}: keeping the existing playback claim")
        set_claim(state, :kept)

      las.num_log_addrs == 0 ->
        send_internal(state, {:s_log, claim_struct(state)}, :claim_set)

      true ->
        Logger.info("CEC #{state.device}: replacing a foreign logical-address configuration")
        send_internal(state, {:s_log, Struct.encode_log_addrs([])}, :claim_clear)
    end
  end

  # Only the three settable flags count; the kernel may add others.
  defp our_claim?(state, las) do
    las.num_log_addrs == 1 and hd(las.log_addr_type) == Struct.log_addr_type(:playback) and
      hd(las.primary_device_type) == Message.device_type(:playback) and las.cec_version == 5 and
      las.vendor_id == 0xFFFFFFFF and las.osd_name == state.osd_name and
      (las.flags &&& 0x07) == Struct.flags_value(:log_addrs, @claim_flags)
  end

  # A claim of ours that the kernel holds without a logical address is
  # cleared and set again, which makes the kernel run the claim anew.
  defp reclaim(state, las) do
    cond do
      not needs_reclaim?(state) ->
        state

      las.num_log_addrs == 0 ->
        Logger.info("CEC #{state.device}: no logical-address configuration; claiming again")
        send_internal(state, {:s_log, claim_struct(state)}, :reclaim_set)

      our_claim?(state, las) ->
        Logger.info("CEC #{state.device}: the claim got no logical address; claiming again")
        send_internal(state, {:s_log, Struct.encode_log_addrs([])}, :reclaim_clear)

      true ->
        Logger.debug("CEC #{state.device}: a foreign configuration replaced ours; leaving it")
        state
    end
  end

  defp needs_reclaim?(state) do
    state.ready? and not state.stopping? and state.claim in [:kept, :claimed] and
      Message.valid_pa?(state.phys_addr) and state.log_addr_mask == 0
  end

  # Armed while a re-claim may be needed; disarmed (and the backoff reset)
  # once it isn't.
  defp arm_reclaim(state) do
    cond do
      not needs_reclaim?(state) ->
        cancel_reclaim(%{state | reclaim_delay: state.reclaim_first})

      state.reclaim_timer == nil ->
        token = make_ref()
        timer = Process.send_after(self(), {:reclaim, token}, state.reclaim_delay)
        %{state | reclaim_timer: {timer, token}}

      true ->
        state
    end
  end

  defp cancel_reclaim(%{reclaim_timer: nil} = state), do: state

  defp cancel_reclaim(%{reclaim_timer: {timer, _token}} = state) do
    _ = Process.cancel_timer(timer)
    %{state | reclaim_timer: nil}
  end

  defp claim_struct(state) do
    Struct.encode_log_addrs(
      num_log_addrs: 1,
      cec_version: 5,
      vendor_id: 0xFFFFFFFF,
      osd_name: state.osd_name,
      primary_device_type: [Message.device_type(:playback)],
      log_addr_type: [Struct.log_addr_type(:playback)],
      all_device_types: [Struct.all_device_type(:playback)],
      flags: @claim_flags
    )
  end

  ## Kernel events

  defp on_kernel_event(state, %{event: :state_change} = event) do
    state =
      if :dropped_events in Struct.flags(:event, event.flags),
        do: state |> bump(:dropped_events) |> resync(),
        else: state

    set_addresses(state, event.phys_addr, event.log_addr_mask)
  end

  defp on_kernel_event(state, %{event: :lost_msgs, lost_msgs: lost}) do
    Logger.warning("CEC #{state.device}: the kernel dropped #{lost} received message(s)")
    notify(state, {:lost_msgs, lost})
    state = %{state | counters: Map.update!(state.counters, :lost_msgs, &(&1 + lost))}
    resync(state)
  end

  defp on_kernel_event(state, _event), do: state

  defp resync(state) do
    state
    |> send_internal(:g_phys, :g_phys)
    |> send_internal(:g_log, {:g_log, :resync})
  end

  # The one place physical/logical addresses change. Becoming configured
  # starts the receiver poll and resumes a waiting One Touch Play; losing
  # the physical address ends being the active source.
  #
  # Losing the configuration, or a new physical address, starts a new
  # generation: results of transmits from an earlier one still answer
  # their callers but no longer change what the adapter believes.
  #
  # Being configured also needs the claim checked (kept or replaced): a
  # mask seen before that may belong to a configuration we are about to
  # clear.
  defp set_addresses(state, pa, mask),
    do: transition(state, %{state | phys_addr: pa, log_addr_mask: mask})

  defp set_claim(state, claim), do: transition(state, %{state | claim: claim, ready?: true})

  defp transition(old, new) do
    was = configured?(old)
    now = configured?(new)

    # We only ever announced the old address, so we aren't the active
    # source at a new one.
    new =
      if (was and not now) or new.phys_addr != old.phys_addr,
        do: %{new | generation: new.generation + 1, active_source?: false},
        else: new

    new =
      cond do
        now and not was -> on_configured(new)
        was and not now -> %{new | receiver: :unknown, tv: :unknown}
        true -> new
      end

    new |> arm_reclaim() |> emit_state()
  end

  defp on_configured(state) do
    state
    |> poll_receiver()
    |> poll_tv_on_configure()
    |> otp_configured()
  end

  defp configured?(state) do
    Message.valid_pa?(state.phys_addr) and state.log_addr_mask != 0 and
      state.claim in [:kept, :claimed]
  end

  defp log_addrs(mask), do: for(la <- 0..15, (mask >>> la &&& 1) == 1, do: la)

  defp our_la(state) do
    if configured?(state), do: state.log_addr_mask |> log_addrs() |> hd(), else: nil
  end

  ## Receiver

  defp poll_receiver(%{receiver_la: nil} = state), do: state

  defp poll_receiver(state) do
    if state.receiver_la == our_la(state) do
      state
    else
      case start_tx(state, state.receiver_la, :poll, nil, 0, nil, :receiver_poll) do
        {:ok, state} -> state
        {:error, _reason, state} -> state
      end
    end
  end

  defp receiver_target(%{receiver_la: nil}), do: {@tv, false}
  defp receiver_target(%{receiver: :absent}), do: {@tv, false}
  defp receiver_target(state), do: {state.receiver_la, true}

  defp set_receiver(state, presence) do
    if state.receiver != presence do
      Logger.info("CEC #{state.device}: receiver at #{state.receiver_la} is #{presence}")
    end

    emit_state(%{state | receiver: presence})
  end

  ## TV

  defp poll_tv_on_configure(%{tv_poll?: false} = state), do: state
  defp poll_tv_on_configure(state), do: poll_tv_now(state)

  # One TV poll at a time. A request while a poll from an earlier
  # generation is still out (unplugged and configured again meanwhile)
  # runs once that stale poll completes, since its result won't count.
  defp poll_tv_now(state) do
    cond do
      not configured?(state) ->
        state

      state.tv_inflight == nil ->
        case start_tx(state, @tv, :poll, nil, 0, nil, :tv_poll) do
          {:ok, state} -> %{state | tv_inflight: state.generation}
          {:error, _reason, state} -> state
        end

      state.tv_inflight != state.generation ->
        %{state | tv_repoll?: true}

      true ->
        state
    end
  end

  defp set_tv(state, presence) do
    if state.tv != presence, do: Logger.info("CEC #{state.device}: TV is #{presence}")
    emit_state(%{state | tv: presence})
  end

  # An acknowledged transmit or a reply means a device holds the address;
  # a NACK means none does. Anything else says nothing.
  defp presence({:error, :nack}), do: :absent
  defp presence({:error, :feature_abort}), do: :present
  defp presence({:error, _reason}), do: nil
  defp presence(_ok), do: :present

  ## Jobs: caller-visible operations made of one or two transmits

  defp job(from, to, kind, payload, reply, timeout) do
    %{
      from: from,
      to: to,
      kind: kind,
      payload: payload,
      reply: reply,
      timeout: timeout,
      fallback?: false,
      stale?: false
    }
  end

  defp start_job(state, %{to: :receiver} = job) do
    {la, fallback?} = receiver_target(state)
    start_job(state, %{job | to: la, fallback?: fallback?})
  end

  defp start_job(state, %{to: to} = job) when not is_integer(to) do
    case resolve(to) do
      {:ok, la} -> start_job(state, %{job | to: la})
      :error -> finish_job(state, job, {:error, {:invalid_message, to}})
    end
  end

  defp start_job(state, %{kind: :send} = job) do
    case start_tx(state, job.to, job.payload, job.reply, job.timeout, nil, {:job, job}) do
      {:ok, state} -> state
      {:error, reason, state} -> finish_job(state, job, {:error, reason})
    end
  end

  defp start_job(state, %{kind: :user_control} = job) do
    case start_tx(state, job.to, {:user_control_pressed, job.payload}, nil, 0, nil, {:press, job}) do
      {:ok, state} -> state
      {:error, reason, state} -> finish_job(state, job, {:error, reason})
    end
  end

  defp resolve(:broadcast), do: {:ok, @broadcast}

  defp resolve(name) when is_atom(name) do
    {:ok, Message.logical_address(name)}
  rescue
    FunctionClauseError -> :error
  end

  defp resolve(_to), do: :error

  defp finish_job(state, %{fallback?: true} = job, {:error, :nack}) do
    Logger.debug("CEC #{state.device}: no receiver at #{job.to}; trying the TV")
    state = set_receiver(state, :absent)
    start_job(state, %{job | to: @tv, fallback?: false})
  end

  defp finish_job(state, job, result) do
    state =
      if job.fallback? do
        case presence(result) do
          nil -> state
          presence -> set_receiver(state, presence)
        end
      else
        state
      end

    state = job_effect(state, job, result)
    GenServer.reply(job.from, result)
    state
  end

  defp job_effect(state, %{stale?: true}, _result), do: state

  defp job_effect(state, %{payload: {:active_source, _}}, :ok),
    do: emit_state(%{state | active_source?: true})

  defp job_effect(state, %{payload: :standby, to: @broadcast}, :ok),
    do: emit_state(%{state | active_source?: false})

  defp job_effect(state, _job, _result), do: state

  ## Transmits

  # Starts one transmit. `cont` says what to do with its result.
  defp start_tx(%{stopping?: true} = state, _to, _body, _reply, _timeout, _from_la, _cont),
    do: {:error, :closed, state}

  defp start_tx(state, to, body, reply, timeout, from_la, cont) do
    with {:ok, from_la} <- initiator(state, to, body, from_la),
         :ok <- check_reply(to, body, reply),
         {:ok, reply_op} <- reply_opcode(reply),
         {:ok, bytes} <- Message.encode(%Message{from: from_la, to: to, body: body}) do
      timeout = if reply_op == 0, do: 0, else: timeout

      struct = Struct.encode_msg(msg: bytes, reply: reply_op, timeout: timeout)
      ref = make_ref()

      case state.mod.send_request(state.transport, {:transmit, struct}) do
        {:ok, id, transport} ->
          timer = Process.send_after(self(), {:tx_deadline, ref}, timeout + state.tx_deadline)

          tx = %{
            seq: nil,
            reply?: reply_op != 0,
            cont: cont,
            timer: timer,
            generation: state.generation
          }

          {:ok,
           %{
             state
             | transport: transport,
               reqs: Map.put(state.reqs, id, {:transmit, ref}),
               txs: Map.put(state.txs, ref, tx)
           }}

        {:error, reason} ->
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp initiator(_state, _to, _body, from) when is_integer(from), do: {:ok, from}

  defp initiator(state, to, body, nil) do
    cond do
      configured?(state) -> {:ok, our_la(state)}
      to == @tv and body in [:poll, :image_view_on, :text_view_on] -> {:ok, @unregistered}
      true -> {:error, :not_configured}
    end
  end

  # The kernel can't wait for a reply to a broadcast or a poll.
  defp check_reply(_to, _body, nil), do: :ok
  defp check_reply(@broadcast, _body, _reply), do: {:error, :einval}
  defp check_reply(_to, :poll, _reply), do: {:error, :einval}
  defp check_reply(_to, _body, _reply), do: :ok

  defp reply_opcode(nil), do: {:ok, 0}
  defp reply_opcode(op) when is_integer(op) and op in 1..0xFF, do: {:ok, op}

  defp reply_opcode(op) when is_atom(op) do
    # 0 would tell the kernel not to wait for a reply at all.
    case Message.opcode(op) do
      byte when is_integer(byte) and byte in 1..0xFF -> {:ok, byte}
      _none -> {:error, {:invalid_message, op}}
    end
  rescue
    FunctionClauseError -> {:error, {:invalid_message, op}}
  end

  defp reply_opcode(op), do: {:error, {:invalid_message, op}}

  # The answer to the CEC_TRANSMIT ioctl: the struct with its sequence, or
  # an errno.
  defp on_tx_reply(state, ref, {:error, errno}),
    do: complete_tx(state, ref, {:error, errno(errno)})

  defp on_tx_reply(state, ref, {:ok, body}) do
    msg = Struct.decode_msg(body)

    cond do
      not Map.has_key?(state.txs, ref) ->
        state

      # The kernel completes some transmits in the ioctl itself (a poll
      # of our own address).
      msg.tx_status != 0 ->
        complete_tx(state, ref, outcome(msg))

      true ->
        state = %{
          state
          | txs: Map.update!(state.txs, ref, &%{&1 | seq: msg.sequence}),
            seqs: Map.put(state.seqs, msg.sequence, ref)
        }

        case List.keytake(state.orphans, msg.sequence, 0) do
          {{_seq, early}, orphans} -> on_tx_result(%{state | orphans: orphans}, early)
          nil -> state
        end
    end
  end

  # A received struct with a sequence: the result of one of our transmits.
  # The kernel queues one per transmit: the transmit status, or with a
  # reply requested, the reply (or its timeout) with both statuses set.
  defp on_tx_result(state, msg) do
    with {:ok, ref} <- Map.fetch(state.seqs, msg.sequence),
         {:ok, tx} <- Map.fetch(state.txs, ref) do
      case outcome(msg) do
        :ok when tx.reply? ->
          state

        result ->
          forward_reply(state, msg)
          complete_tx(state, ref, result)
      end
    else
      :error ->
        orphans = Enum.take([{msg.sequence, msg} | state.orphans], @max_orphans)
        %{state | orphans: orphans}
    end
  end

  defp outcome(msg) do
    cond do
      msg.tx_status != 0 and (msg.tx_status &&& 0x01) == 0 ->
        {:error, Struct.tx_outcome(msg.tx_status)}

      msg.rx_status != 0 ->
        case Struct.rx_outcome(msg.rx_status) do
          :ok -> reply_message(msg)
          :none -> {:error, :error}
          other -> {:error, other}
        end

      true ->
        :ok
    end
  end

  defp reply_message(msg) do
    case Message.decode(msg.msg) do
      {:ok, message} -> {:ok, message}
      {:error, _} -> {:error, :unexpected_reply}
    end
  end

  # A reply is a bus message like any other, so subscribers see it too.
  defp forward_reply(state, msg) do
    if Struct.rx_outcome(msg.rx_status) in [:ok, :feature_abort] do
      case Message.decode(msg.msg) do
        {:ok, message} -> notify(state, {:message, message})
        {:error, _} -> :ok
      end
    end
  end

  defp errno(errno) when errno in [:eperm, :enonet], do: :not_configured
  defp errno(:ebusy), do: :busy
  defp errno(errno), do: errno

  defp complete_tx(state, ref, result) do
    case Map.pop(state.txs, ref) do
      {nil, _txs} ->
        state

      {tx, txs} ->
        _ = Process.cancel_timer(tx.timer)
        state = %{state | txs: txs, seqs: Map.delete(state.seqs, tx.seq)}

        state =
          if match?({:error, _}, result) and tx.cont not in [:receiver_poll, :tv_poll],
            do: bump(state, :tx_errors),
            else: state

        cont = if tx.generation == state.generation, do: tx.cont, else: stale(tx.cont)
        continue(state, cont, result)
    end
  end

  # What is left of a continuation from an earlier generation: callers
  # still get their result, but there is no receiver fallback and no
  # change to the active source or receiver state.
  defp stale({:job, job}), do: {:job, %{job | fallback?: false, stale?: true}}
  defp stale({:press, job}), do: {:press, %{job | fallback?: false, stale?: true}}
  defp stale({:otp, id, step}), do: {:otp_stale, id, step}
  defp stale(:receiver_poll), do: :ignore
  defp stale(:tv_poll), do: :tv_poll_stale
  defp stale(:follower), do: :follower

  defp continue(state, {:job, job}, result), do: finish_job(state, job, result)

  defp continue(state, {:press, job}, :ok) do
    # The receiver acknowledged the press, so the release stays there.
    {state, job} =
      if job.fallback?,
        do: {set_receiver(state, :present), %{job | fallback?: false}},
        else: {state, job}

    case start_tx(state, job.to, :user_control_released, nil, 0, nil, {:job, job}) do
      {:ok, state} -> state
      {:error, reason, state} -> finish_job(state, job, {:error, reason})
    end
  end

  defp continue(state, {:press, job}, error), do: finish_job(state, job, error)

  defp continue(state, :receiver_poll, result) do
    case presence(result) do
      nil -> state
      presence -> set_receiver(state, presence)
    end
  end

  defp continue(state, :tv_poll, result) do
    state = %{state | tv_inflight: nil}

    case presence(result) do
      nil ->
        notify(state, {:tv_poll, :unknown})
        state

      presence ->
        state = set_tv(state, presence)
        notify(state, {:tv_poll, presence})
        state
    end
  end

  defp continue(state, :tv_poll_stale, _result) do
    state = %{state | tv_inflight: nil}
    if state.tv_repoll?, do: poll_tv_now(%{state | tv_repoll?: false}), else: state
  end

  defp continue(state, {:otp, id, step}, result), do: otp_step(state, id, step, result)

  defp continue(state, {:otp_stale, id, :active_source}, result),
    do: otp_step(state, id, :active_source_stale, result)

  defp continue(state, {:otp_stale, id, step}, result), do: otp_step(state, id, step, result)
  defp continue(state, :ignore, _result), do: state

  defp continue(state, :follower, :ok), do: state

  defp continue(state, :follower, {:error, reason}) do
    Logger.debug("CEC #{state.device}: follower reply failed (#{inspect(reason)})")
    state
  end

  # Fails every waiting caller, e.g. when the device goes away.
  # One Touch Play first: its continuations would otherwise finish it with
  # whatever they make of the failed transmit.
  defp fail_all(state, reason) do
    state = if state.otp, do: otp_finish(state, {:error, reason}), else: state
    Enum.reduce(Map.keys(state.txs), state, &complete_tx(&2, &1, {:error, reason}))
  end

  ## Received messages

  defp on_received(state, msg) do
    case Message.decode(msg.msg) do
      {:ok, message} ->
        notify(state, {:message, message})
        follow(state, message)

      {:error, _} ->
        state
    end
  end

  defp follow(%{follower: :unavailable} = state, _message), do: state

  defp follow(state, message) do
    ctx = %{
      la: our_la(state),
      phys_addr: state.phys_addr,
      active_source?: state.active_source?,
      power_status: state.power_status,
      handled: handled(state)
    }

    {replies, effects} = Follower.handle(message, ctx)
    state = Enum.reduce(effects, state, &apply_effect/2)

    Enum.reduce(replies, state, fn {to, body}, state ->
      case start_tx(state, to, body, nil, 0, nil, :follower) do
        {:ok, state} -> state
        {:error, _reason, state} -> state
      end
    end)
  end

  defp apply_effect({:active_source, active?}, state),
    do: emit_state(%{state | active_source?: active?})

  defp apply_effect({:standby, from}, state), do: %{state | last_standby: from}

  defp handled(state) do
    Enum.reduce(state.subs, MapSet.new(), fn {_pid, sub}, acc ->
      MapSet.union(acc, sub.handles)
    end)
  end

  ## One Touch Play

  defp otp_join(%{otp: %{} = otp} = state, from, _opts) do
    %{state | otp: %{otp | waiters: [from | otp.waiters]}}
  end

  defp otp_join(state, from, opts) do
    otp = %{
      id: make_ref(),
      waiters: [from],
      stage: nil,
      ivo_sent?: false,
      timer: nil,
      deadline: now_ms() + Keyword.get(opts, :wait_ms, @otp_wait),
      sam?: Keyword.get(opts, :system_audio_mode, state.system_audio_mode)
    }

    state = %{state | otp: otp}

    cond do
      configured?(state) ->
        otp_image_view_on(state)

      # Without a physical address the kernel still lets Unregistered
      # wake the TV.
      not Message.valid_pa?(state.phys_addr) ->
        state
        |> otp_tx(@tv, :image_view_on, nil, @unregistered, :ivo_unconfigured)
        |> otp_wait()

      # Configuring: the claim is in progress, transmits would get ENONET.
      true ->
        otp_wait(state)
    end
  end

  # Every wait in a run shares the run's one deadline.
  defp otp_wait(%{otp: otp} = state) do
    timer = Process.send_after(self(), {:otp_timeout, otp.id}, max(otp.deadline - now_ms(), 0))
    %{state | otp: %{otp | stage: :waiting, timer: timer}}
  end

  defp otp_configured(%{otp: %{stage: :waiting} = otp} = state) do
    _ = otp.timer && Process.cancel_timer(otp.timer)
    state = %{state | otp: %{otp | timer: nil}}
    if otp.ivo_sent?, do: otp_active_source(state), else: otp_image_view_on(state)
  end

  defp otp_configured(state), do: state

  defp otp_image_view_on(state) do
    state = put_in(state.otp.stage, :image_view_on)
    otp_tx(state, @tv, :image_view_on, nil, nil, :image_view_on)
  end

  defp otp_active_source(state) do
    if configured?(state) do
      state = put_in(state.otp.stage, :active_source)
      otp_tx(state, @broadcast, {:active_source, state.phys_addr}, nil, nil, :active_source)
    else
      # Hotplug dropped while Image View On was out: wait for the claim
      # again. A new id keeps an earlier wait's timeout from ending this one.
      otp_wait(%{state | otp: %{state.otp | id: make_ref(), ivo_sent?: true}})
    end
  end

  defp otp_tx(state, to, body, reply, from_la, step) do
    timeout = if reply, do: @reply_timeout, else: 0

    case start_tx(state, to, body, reply, timeout, from_la, {:otp, state.otp.id, step}) do
      {:ok, state} ->
        if step == :ivo_unconfigured, do: put_in(state.otp.ivo_sent?, true), else: state

      {:error, reason, state} ->
        otp_step(state, state.otp.id, step, {:error, reason})
    end
  end

  defp otp_step(%{otp: %{id: id} = otp} = state, id, step, result) do
    case {step, otp.stage} do
      {:ivo_unconfigured, _stage} ->
        Logger.debug("CEC #{state.device}: unconfigured Image View On: #{inspect(result)}")
        state

      {:image_view_on, :image_view_on} ->
        # No TV (an AVR-only setup) NACKs this; Active Source still matters.
        if result != :ok,
          do: Logger.debug("CEC #{state.device}: Image View On: #{inspect(result)}")

        otp_active_source(state)

      {:active_source, :active_source} when result == :ok ->
        state = emit_state(%{state | active_source?: true})
        otp_system_audio(state)

      {:active_source, :active_source} ->
        otp_finish(state, result)

      # Sent before an unplug: it went out, but doesn't make us active now.
      {:active_source_stale, :active_source} ->
        otp_finish(state, result)

      {:system_audio_mode, :system_audio_mode} ->
        if not match?({:ok, _}, result) do
          Logger.info("CEC #{state.device}: System Audio Mode Request: #{inspect(result)}")
        end

        otp_finish(state, :ok)

      _stale ->
        state
    end
  end

  defp otp_step(state, _id, _step, _result), do: state

  defp otp_system_audio(%{otp: %{sam?: true}, receiver_la: la} = state)
       when is_integer(la) and la != @tv do
    if state.receiver == :absent do
      otp_finish(state, :ok)
    else
      state = put_in(state.otp.stage, :system_audio_mode)
      body = {:system_audio_mode_request, state.phys_addr}
      otp_tx(state, la, body, :set_system_audio_mode, nil, :system_audio_mode)
    end
  end

  defp otp_system_audio(state), do: otp_finish(state, :ok)

  defp otp_finish(%{otp: otp} = state, result) do
    _ = otp.timer && Process.cancel_timer(otp.timer)
    Enum.each(otp.waiters, &GenServer.reply(&1, result))
    %{state | otp: nil}
  end

  ## Requests to the device

  defp send_internal(state, request, purpose) do
    case state.mod.send_request(state.transport, request) do
      {:ok, id, transport} ->
        %{state | transport: transport, reqs: Map.put(state.reqs, id, purpose)}

      {:error, reason} ->
        Logger.debug("CEC #{state.device}: #{inspect(purpose)} not sent (#{inspect(reason)})")
        state
    end
  end

  ## Subscribers and info

  defp notify(state, event) do
    Enum.each(state.subs, fn {pid, _sub} -> send(pid, {:cec, state.device, event}) end)
  end

  defp emit_state(state) do
    summary = summary(state)

    if summary == state.last_state do
      state
    else
      notify(state, {:state, summary})
      %{state | last_state: summary}
    end
  end

  defp summary(state) do
    %{
      phys_addr: state.phys_addr,
      log_addrs: if(configured?(state), do: log_addrs(state.log_addr_mask), else: []),
      configured?: configured?(state),
      active_source?: state.active_source?,
      receiver: state.receiver,
      tv: state.tv
    }
  end

  defp info_map(state) do
    {target, _fallback?} = receiver_target(state)

    state
    |> summary()
    |> Map.merge(%{
      device: state.device,
      ready?: state.ready?,
      caps: caps_info(state.caps),
      connector: state.connector && Map.delete(state.connector, :raw),
      claim: state.claim,
      follower: state.follower,
      osd_name: state.osd_name,
      power_status: state.power_status,
      last_standby: state.last_standby,
      receiver_la: state.receiver_la,
      receiver_target: target,
      system_audio_mode: state.system_audio_mode,
      counters: state.counters
    })
  end

  defp caps_info(nil), do: nil

  defp caps_info(caps),
    do: %{caps | capabilities: Struct.flags(:caps, caps.capabilities)}

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp bump(state, counter),
    do: %{state | counters: Map.update!(state.counters, counter, &(&1 + 1))}

  @doc false
  @spec truncate_osd_name(String.t()) :: String.t()
  def truncate_osd_name(name) when is_binary(name) do
    if byte_size(name) <= @osd_name_max do
      name
    else
      name
      |> String.graphemes()
      |> Enum.reduce_while("", fn g, acc ->
        if byte_size(acc) + byte_size(g) <= @osd_name_max,
          do: {:cont, acc <> g},
          else: {:halt, acc}
      end)
    end
  end
end
