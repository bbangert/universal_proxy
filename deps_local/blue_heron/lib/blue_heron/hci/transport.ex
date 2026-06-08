# SPDX-FileCopyrightText: 2020 Connor Rigby
# SPDX-FileCopyrightText: 2021 Troels Brødsgaard
# SPDX-FileCopyrightText: 2022 Alex McLain
# SPDX-FileCopyrightText: 2023 Markus Hutzler
# SPDX-FileCopyrightText: 2024 Alexandre Cadeau
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule BlueHeron.HCI.Transport do
  @moduledoc """
  Handles sending and receiving HCI Packets
  """
  require Logger
  use GenServer

  alias BlueHeron.HCI.Command.{
    ControllerAndBaseband,
    InformationalParameters,
    LEController
  }

  alias BlueHeron.HCI.Transport.BroadcomInit

  import BlueHeron.HCI.Deserializable, only: [deserialize: 1]
  import BlueHeron.HCI.Serializable, only: [serialize: 1]

  @type command_complete :: %BlueHeron.HCI.Event.CommandComplete{}
  @type command_status :: %BlueHeron.HCI.Event.CommandStatus{}

  @doc "Checks if setup is complete on the transport"
  @spec setup_complete?() :: boolean()
  def setup_complete? do
    GenServer.call(__MODULE__, :setup_complete?)
  end

  @doc "Send an HCI frame"
  @spec send_hci(map()) ::
          {:ok, command_complete() | command_status()} | {:error, :setup_incomplete | :timeout}
  def send_hci(frame) do
    GenServer.call(__MODULE__, {:send_hci, frame})
  end

  @doc """
  Buffer an ACL frame to be sent
  """
  @spec buffer_acl(map()) :: :ok
  def buffer_acl(frame) do
    BlueHeron.ACLBuffer.buffer(frame)
  end

  @doc false
  @spec send_acl(map()) :: :ok | {:error, :setup_incomplete}
  def send_acl(frame) do
    GenServer.call(__MODULE__, {:send_acl, frame})
  end

  @setup_params [
    :local_name,
    :acl_packet_length,
    :acl_packet_number,
    :syn_packet_length,
    :syn_packet_number,
    :supported_commands,
    :bd_addr,
    :hci_revision,
    :hci_version,
    :lmp_pal_subversion,
    :lmp_pal_version,
    :manufacturer_name,
    :white_list_size,
    :acl_data_packet_length,
    :total_num_acl_data_packets
  ]

  @type setup_param ::
          :local_name
          | :acl_packet_length
          | :acl_packet_number
          | :syn_packet_length
          | :syn_packet_number
          | :supported_commands
          | :bd_addr
          | :hci_revision
          | :hci_version
          | :lmp_pal_subversion
          | :lmp_pal_version
          | :manufacturer_name
          | :white_list_size
          | :acl_data_packet_length
          | :total_num_acl_data_packets

  @doc """
  Returns the value of a setup param or an error if the transport is not ready yet.
  """
  @spec get_setup_param(setup_param()) :: {:ok, term()} | {:error, :setup_incomplete}
  def get_setup_param(key) when key in @setup_params do
    GenServer.call(__MODULE__, {:get_setup_param, key})
  end

  @default_name "BlueHeron"

  @default_setup_commands [
    %ControllerAndBaseband.Reset{},
    %InformationalParameters.ReadLocalVersion{},
    %InformationalParameters.ReadBdAddr{},
    %ControllerAndBaseband.ReadLocalName{},
    %InformationalParameters.ReadLocalSupportedCommands{},
    %InformationalParameters.ReadBdAddr{},
    %InformationalParameters.ReadBufferSize{},
    # %InformationalParameters.ReadLocalSupportedFeatures{},
    %ControllerAndBaseband.SetControllerToHostFlowControl{flow_control_enable: 1},
    %ControllerAndBaseband.HostBufferSize{
      host_acl_data_packet_length: 256,
      host_synchronous_data_packet_length: 0,
      host_total_num_acl_data_packets: 20,
      host_total_num_synchronous_data_packets: 0
    },
    %ControllerAndBaseband.SetEventMask{enhanced_flush_complete: false},
    %ControllerAndBaseband.WriteSimplePairingMode{enabled: true},
    %ControllerAndBaseband.WritePageTimeout{timeout: 0x60},
    %ControllerAndBaseband.WriteClassOfDevice{class: 0x0C027A},
    %ControllerAndBaseband.WriteLocalName{name: @default_name},
    %ControllerAndBaseband.WriteInquiryMode{inquiry_mode: 0x0},
    %ControllerAndBaseband.WriteSecureConnectionsHostSupport{enabled: false},
    %ControllerAndBaseband.WriteScanEnable{scan_enable: 0x01},
    %ControllerAndBaseband.WriteDefaultErroneousDataReporting{enabled: true},
    %LEController.ReadBufferSizeV1{},
    %ControllerAndBaseband.WriteLEHostSupport{le_supported_host_enabled: true},
    %LEController.ReadWhiteListSize{}
  ]

  @default_transport_init_backoff_ms :timer.seconds(5)

  @doc false
  def start_link(args) do
    GenServer.start_link(__MODULE__, args, name: __MODULE__)
  end

  @doc false
  def transport_data(<<0x04, hci_bin::binary>>) do
    hci = deserialize(hci_bin)
    GenServer.cast(__MODULE__, {:transport_data, :hci, hci})
  end

  def transport_data(<<0x02, acl_bin::binary>>) do
    require Logger
    Logger.debug("ACL raw (#{byte_size(acl_bin)}B): #{inspect(acl_bin, base: :hex, limit: 40)}")
    acl = BlueHeron.ACL.deserialize(acl_bin)
    GenServer.cast(__MODULE__, {:transport_data, :acl, acl})
  end

  def transport_data(<<0x01, _iso::binary>>) do
    :noop
  end

  @impl GenServer
  def init(args) do
    # Distinguish fresh boot from supervisor-driven restart in RingLogger.
    # `:persistent_term` survives module reloads and GenServer crashes but
    # not VM restarts, so this counter resets on power-cycle / reboot.
    attempt = :persistent_term.get({__MODULE__, :init_count}, 0) + 1
    :ok = :persistent_term.put({__MODULE__, :init_count}, attempt)
    Logger.info("HCI Transport init: starting (attempt #{attempt})")

    all_env = Application.get_all_env(:blue_heron)

    firmware_path =
      Keyword.get(all_env, :firmware_path, Application.app_dir(:blue_heron, "priv/firmware/brcm"))

    state = %{
      transport: nil,
      transport_init_backoff_ms: @default_transport_init_backoff_ms,
      transport_init_timer: nil,
      setup_commands: @default_setup_commands,
      current: nil,
      current_timer: nil,
      setup_complete: false,
      caller: nil,
      setup_params: %{},
      firmware_path: firmware_path
    }

    send(self(), {:initialize_transport, args})
    {:ok, state}
  end

  @impl GenServer
  def handle_info({:initialize_transport, args}, state) do
    case BlueHeron.HCI.Transport.UART.start_link(args) do
      {:ok, pid} ->
        Logger.info("Initialized HCI Transport: #{inspect(pid)}")
        {:noreply, %{state | transport: pid}, {:continue, :setup_transport}}

      {:error, reason} ->
        Logger.error("Initialize HCI Transport error: #{inspect(reason)}")
        retry_time_ms = state.transport_init_backoff_ms + :timer.seconds(5)

        timer =
          Process.send_after(
            self(),
            {:initialize_transport, args},
            state.transport_init_backoff_ms
          )

        new_state = %{
          state
          | transport: nil,
            transport_init_backoff_ms: retry_time_ms,
            transport_init_timer: timer
        }

        {:noreply, new_state}
    end
  end

  def handle_info(:current_timeout, state) do
    new_state = cancel_timer(state)

    case state.caller do
      nil ->
        Logger.warning("Setup command timeout: #{inspect(state.current)}")
        :ok = BlueHeron.HCI.Transport.UART.flush(state.transport)

        case state.current do
          {:raw_hci, _opcode, bin} ->
            :ok = BlueHeron.HCI.Transport.UART.send_command(state.transport, bin)

          command ->
            hci_bin = serialize(command)
            :ok = BlueHeron.HCI.Transport.UART.send_command(state.transport, hci_bin)
        end

        timer = Process.send_after(self(), :current_timeout, 5000)
        {:noreply, %{new_state | current_timer: timer}}

      caller ->
        Logger.warning("HCI command timeout: #{inspect(state.current)}")
        _ = GenServer.reply(caller, {:error, :timeout})
        {:noreply, %{new_state | current: nil, caller: nil}}
    end
  end

  def handle_info(:continue_setup, state) do
    {:noreply, state, {:continue, :setup_transport}}
  end

  @impl GenServer
  def handle_continue(:setup_transport, %{setup_commands: [{:delay, ms} | rest]} = state) do
    new_state = cancel_timer(state)
    Process.send_after(self(), :continue_setup, ms)
    {:noreply, %{new_state | setup_commands: rest}}
  end

  def handle_continue(:setup_transport, %{setup_commands: [{:raw_hci, bin} | rest]} = state) do
    new_state = cancel_timer(state)
    <<opcode::binary-2, _rest::binary>> = bin
    :ok = BlueHeron.HCI.Transport.UART.send_command(new_state.transport, bin)
    timer = Process.send_after(self(), :current_timeout, 5000)

    {:noreply,
     %{new_state | setup_commands: rest, current: {:raw_hci, opcode, bin}, current_timer: timer}}
  end

  # Flush the host UART RX buffer between Broadcom firmware-load
  # (`LaunchRAM`) and the first post-firmware HCI command. The Linux
  # `btbcm`/`hci_bcm` driver achieves the same effect implicitly
  # because it calls `host_set_baudrate(hu, init_speed)` post-firmware,
  # and `tty_set_termios` flushes the FIFOs as a side effect of
  # re-applying termios. Without that flush, garbage bytes the
  # BCM4345C0 emits during ROM→patch handoff corrupt the framer's
  # mid-frame state, so the next Reset's Command Complete is never
  # parsed correctly and the host thinks Reset timed out.
  #
  # Important: only flush :receive. Do NOT call `Circuits.UART.drain/1`
  # here — drain calls `tcdrain(3)` which blocks until the TX buffer is
  # empty, and on a freshly-restarted BCM chip CTS may be temporarily
  # de-asserted, in which case drain blocks forever. Even with a
  # GenServer.call timeout + try/catch on this side, the underlying
  # UART GenServer's handle_call stays stuck and all subsequent
  # operations on that pid time out → setup fails → max_restarts →
  # BlueHeron.Application.start never returns → StartupGuard never
  # validates the firmware → Nerves bootloader auto-reverts on the
  # next boot. Observed empirically on Pi 3 B+ 2026-05-22.
  #
  # Defensive: a flush failure must NOT crash the transport (same
  # bootloop reasoning). Caught and logged.
  def handle_continue(
        :setup_transport,
        %{setup_commands: [:uart_flush_rx | rest]} = state
      ) do
    new_state = cancel_timer(state)
    Logger.info("UART flush RX: starting")

    result =
      try do
        BlueHeron.HCI.Transport.UART.flush(new_state.transport, :receive)
      catch
        kind, reason -> {:caught, kind, reason}
      end

    case result do
      :ok ->
        Logger.info("UART flush RX: ok")

      other ->
        Logger.warning("UART flush RX: non-ok result #{inspect(other)}; continuing anyway")
    end

    {:noreply, %{new_state | setup_commands: rest}, {:continue, :setup_transport}}
  end

  # Re-apply host UART termios between firmware-load and the first
  # post-firmware HCI command. Linux's `bcm_setup` sequence calls
  # `host_set_baudrate(hu, init_speed)` post-firmware even when the
  # baud isn't changing — `serdev_device_set_baudrate` →
  # `tty_set_termios` is what we're mirroring. tty_set_termios does
  # more than just set baud: it drops/re-arms the FIFOs and toggles
  # the modem control lines as a side effect of termios re-apply.
  # Empirically the BCM4345C5 on Pi 3 B+ refuses to respond to ANY
  # post-LaunchRAM HCI command (Reset 0x0C03, UpdateBaudrate 0xFC18)
  # without this trigger — the chip emits zero bytes back even on a
  # well-formed command at the correct baud. Observed 2026-05-22.
  #
  # `Circuits.UART.configure/2` at the SAME baud as before is enough
  # to trigger termios re-apply at the Linux serdev layer. Hardcoded
  # opts because they're constants for the rpi3 BT path and we want
  # this step to be self-contained (no state plumbing).
  #
  # Defensive: a configure failure must NOT crash the transport.
  # Same reasoning as :uart_flush_rx — a crash here cascades into
  # supervisor restart, init re-runs, the chip is now in a
  # half-initialized post-LaunchRAM state for the next attempt,
  # and the loop never recovers.
  def handle_continue(
        :setup_transport,
        %{setup_commands: [:uart_configure_resync | rest]} = state
      ) do
    new_state = cancel_timer(state)
    Logger.info("UART configure resync: starting (115200 8N1 :hardware)")

    result =
      try do
        BlueHeron.HCI.Transport.UART.configure(new_state.transport,
          speed: 115_200,
          flow_control: :hardware
        )
      catch
        kind, reason -> {:caught, kind, reason}
      end

    case result do
      :ok ->
        Logger.info("UART configure resync: ok")

      other ->
        Logger.warning(
          "UART configure resync: non-ok result #{inspect(other)}; continuing anyway"
        )
    end

    {:noreply, %{new_state | setup_commands: rest}, {:continue, :setup_transport}}
  end

  # Pulse a UART BREAK to wake a Broadcom controller from any
  # post-firmware sleep state. Some Cypress/Broadcom patch firmwares
  # enable sleep mode by default after `LaunchRAM`; in that state the
  # chip ignores all HCI commands (including `Set_Sleep_Mode` itself)
  # until it observes a UART BREAK or BT_DEV_WAKE GPIO transition.
  # A 20ms break is the cheapest possible wake signal we can send
  # purely over the existing UART path.
  #
  # Same blast-radius rules as the other defensive setup steps:
  # try/catch wraps the call; a non-`:ok` result is logged and the
  # setup queue continues so we don't crash-loop the transport.
  def handle_continue(
        :setup_transport,
        %{setup_commands: [:uart_break_wake | rest]} = state
      ) do
    new_state = cancel_timer(state)
    Logger.info("UART break wake: pulsing BREAK for 20ms")

    result =
      try do
        BlueHeron.HCI.Transport.UART.pulse_break(new_state.transport, 20)
      catch
        kind, reason -> {:caught, kind, reason}
      end

    case result do
      :ok ->
        Logger.info("UART break wake: ok")

      other ->
        Logger.warning("UART break wake: non-ok result #{inspect(other)}; continuing anyway")
    end

    {:noreply, %{new_state | setup_commands: rest}, {:continue, :setup_transport}}
  end

  def handle_continue(:setup_transport, %{setup_commands: [command | rest]} = state) do
    new_state = cancel_timer(state)
    hci_bin = serialize(command)
    :ok = BlueHeron.HCI.Transport.UART.send_command(new_state.transport, hci_bin)
    timer = Process.send_after(self(), :current_timeout, 5000)
    {:noreply, %{new_state | setup_commands: rest, current: command, current_timer: timer}}
  end

  def handle_continue(:setup_transport, %{setup_commands: []} = state) do
    :ok = BlueHeron.Registry.broadcast({:BLUETOOTH_EVENT_STATE, :HCI_STATE_WORKING})
    new_state = cancel_timer(state)
    {:noreply, %{new_state | setup_complete: true}}
  end

  @impl GenServer
  # Handle CommandComplete for raw HCI commands (firmware download records)
  def handle_cast(
        {:transport_data, :hci, packet},
        %{setup_complete: false, current: {:raw_hci, opcode, _bin}} = state
      ) do
    case packet do
      %BlueHeron.HCI.Event.CommandComplete{opcode: ^opcode} ->
        new_state = %{cancel_timer(state) | current: nil}
        {:noreply, new_state, {:continue, :setup_transport}}

      packet ->
        Logger.error("Unknown HCI packet during firmware download: #{inspect(packet)}")
        {:noreply, state}
    end
  end

  def handle_cast(
        {:transport_data, :hci, packet},
        %{setup_complete: false, current: %{opcode: opcode} = current} = state
      ) do
    case packet do
      %BlueHeron.HCI.Event.CommandComplete{
        opcode: ^opcode,
        return_parameters: %{status: 0} = return
      } ->
        new_setup_params = Map.merge(state.setup_params, Map.delete(return, :status))
        additional = maybe_vendor_init(current, new_setup_params, state)

        new_state = %{
          cancel_timer(state)
          | setup_params: new_setup_params,
            current: nil,
            setup_commands: additional ++ state.setup_commands
        }

        {:noreply, new_state, {:continue, :setup_transport}}

      %BlueHeron.HCI.Event.CommandComplete{
        opcode: ^opcode,
        return_parameters: %{status: status} = return
      } ->
        status_message = BlueHeron.ErrorCode.to_atom(status)

        Logger.error(
          "Setup Command error: #{status} (#{inspect(status_message)}) return: #{inspect(return)} command: #{inspect(current)}"
        )

        new_state = %{cancel_timer(state) | current: nil}
        {:noreply, new_state, {:continue, :setup_transport}}

      packet ->
        Logger.error("Unknown HCI packet during setup: #{inspect(packet)}")
        {:noreply, state}
    end
  end

  def handle_cast(
        {:transport_data, :hci, packet},
        %{setup_complete: true, current: %{opcode: opcode}, caller: caller} = state
      ) do
    case packet do
      %BlueHeron.HCI.Event.CommandComplete{
        opcode: ^opcode
      } = command_complete ->
        _ = GenServer.reply(caller, {:ok, command_complete})
        new_state = %{cancel_timer(state) | current: nil, caller: nil}
        {:noreply, new_state}

      %BlueHeron.HCI.Event.CommandStatus{num_hci_command_packets: 1, opcode: ^opcode} =
          command_status ->
        _ = GenServer.reply(caller, {:ok, command_status})
        new_state = %{cancel_timer(state) | current: nil, caller: nil}
        {:noreply, new_state}

      packet ->
        Logger.error("Unknown HCI packet during command: #{inspect(packet)}")
        {:noreply, state}
    end
  end

  def handle_cast(
        {:transport_data, :hci, packet},
        %{setup_complete: true} = state
      ) do
    Logger.info("HCI Packet: #{inspect(packet)}")
    :ok = BlueHeron.Registry.broadcast({:HCI_EVENT_PACKET, packet})
    {:noreply, state}
  end

  def handle_cast(
        {:transport_data, :acl, %BlueHeron.ACL{handle: handle} = packet},
        %{setup_complete: true} = state
      ) do
    :ok = BlueHeron.Registry.broadcast({:HCI_ACL_DATA_PACKET, packet})
    # Acknowledge the received packet to the controller so it frees the buffer slot.
    # HCI Host_Number_Of_Completed_Packets (OGF 0x03, OCF 0x0035, opcode 0x0C35).
    # This command generates no CommandComplete/CommandStatus event per spec.
    ack = <<0x35, 0x0C, 5, 1, handle::little-16, 1::little-16>>
    Logger.info("Sending C→H ACK for handle #{handle}")
    :ok = BlueHeron.HCI.Transport.UART.send_command(state.transport, ack)
    {:noreply, state}
  end

  def handle_cast(
        {:transport_data, :acl, _nil_packet},
        %{setup_complete: true} = state
      ) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:get_setup_param, param}, _from, %{setup_complete: true} = state) do
    value = Map.fetch!(state.setup_params, param)
    {:reply, {:ok, value}, state}
  end

  def handle_call(
        {:send_hci, command},
        from,
        %{setup_complete: true, current: nil, caller: nil} = state
      ) do
    hci_bin = serialize(command)
    :ok = BlueHeron.HCI.Transport.UART.send_command(state.transport, hci_bin)
    timer = Process.send_after(self(), :current_timeout, 5000)
    {:noreply, %{state | current: command, current_timer: timer, caller: from}}
  end

  def handle_call(
        {:send_acl, acl},
        _from,
        %{setup_complete: true} = state
      ) do
    acl_bin = BlueHeron.ACL.serialize(acl)
    :ok = BlueHeron.HCI.Transport.UART.send_acl(state.transport, acl_bin)
    {:reply, :ok, state}
  end

  def handle_call(:setup_complete?, _from, %{setup_complete: setup_complete} = state) do
    {:reply, setup_complete, state}
  end

  def handle_call(_call, _from, %{setup_complete: false} = state) do
    {:reply, {:error, :setup_incomplete}, state}
  end

  defp cancel_timer(state) do
    if state.current_timer do
      _ = Process.cancel_timer(state.current_timer)
      %{state | current_timer: nil}
    else
      state
    end
  end

  # Check if we just completed ReadLocalVersion and need vendor-specific init
  defp maybe_vendor_init(
         %InformationalParameters.ReadLocalVersion{},
         setup_params,
         state
       ) do
    manufacturer = Map.get(setup_params, :manufacturer_name, 0)

    if BroadcomInit.broadcom?(manufacturer) do
      BroadcomInit.vendor_init_commands(setup_params, state.firmware_path)
    else
      []
    end
  end

  defp maybe_vendor_init(_command, _setup_params, _state), do: []
end
