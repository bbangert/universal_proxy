defmodule UniversalProxy.ESPHome.Connection do
  @moduledoc """
  ThousandIsland handler for a single ESPHome Native API client connection.

  Each accepted TCP connection gets its own handler process managed by
  ThousandIsland. It buffers incoming data, decodes plaintext protocol
  frames, and dispatches protobuf messages to the appropriate handler.

  Serial proxy instances are resolved at connection time from the ESPHome
  Server's instance map. When a client sends `SerialProxyConfigureRequest`,
  the corresponding UART port is opened. When the client disconnects, all
  ports opened by this connection are automatically closed.
  """

  use ThousandIsland.Handler

  require Logger

  alias UniversalProxy.ESPHome.{DeviceConfig, MessageTypes, Protocol, Server, ZWave}
  alias UniversalProxy.{Protos, UART}

  @pubsub UniversalProxy.PubSub

  @impl ThousandIsland.Handler
  def handle_connection(socket, _state) do
    device_config = Server.get_config()
    instance_map = Server.instance_map()
    Server.register_connection(self())
    peer = peer_label(socket)

    Phoenix.PubSub.subscribe(@pubsub, ZWave.home_id_changed_topic())

    Logger.info("ESPHome client connected from #{peer} (#{map_size(instance_map)} serial proxy instances available)")

    {:continue, %{
      buffer: <<>>,
      device_config: device_config,
      peer: peer,
      instance_map: instance_map,
      opened_ports: %{},
      zwave_subscribed: false
    }}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    new_buffer = state.buffer <> data
    state = %{state | buffer: new_buffer}

    case process_buffer(socket, state) do
      {:ok, state} ->
        {:continue, state}

      {:close, state} ->
        close_all_ports(state)
        {:close, state}

      {:error, reason, state} ->
        close_all_ports(state)
        {:error, reason, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    close_all_ports(state)
    Logger.info("ESPHome client #{state.peer} disconnected (closed)")
    :ok
  end

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    close_all_ports(state)
    Logger.warning("ESPHome client #{state.peer} connection error: #{inspect(reason)}")
    :ok
  end

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state) do
    close_all_ports(state)
    Logger.warning("ESPHome client #{state.peer} timed out")
    :ok
  end

  # -- PubSub for UART data --

  @impl GenServer
  def handle_info({:uart_data, message}, {socket, state}) do
    instance = find_instance_for_friendly_name(state, message.name)

    if instance do
      response = %Protos.SerialProxyDataReceived{
        instance: instance,
        data: message.data
      }

      send_message(response, socket)
    end

    {:noreply, {socket, state}}
  end

  def handle_info({:zwave_frame, data}, {socket, state}) do
    if state.zwave_subscribed do
      frame = %Protos.ZWaveProxyFrame{data: data}
      send_message(frame, socket)
    end

    {:noreply, {socket, state}}
  end

  def handle_info({:zwave_home_id_changed, home_id_bytes}, {socket, state}) do
    msg = %Protos.ZWaveProxyRequest{
      type: :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE,
      data: home_id_bytes
    }

    send_message(msg, socket)
    {:noreply, {socket, state}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Frame Processing --

  defp process_buffer(socket, state) do
    case Protocol.decode_frame(state.buffer) do
      {:ok, type_id, payload, rest} ->
        case handle_message(type_id, payload, socket, %{state | buffer: rest}) do
          {:ok, state} -> process_buffer(socket, state)
          {:close, _state} = result -> result
        end

      {:incomplete, _} ->
        {:ok, state}

      {:error, reason} ->
        Logger.warning("ESPHome client #{state.peer} protocol error: #{inspect(reason)}")
        {:error, reason, state}
    end
  end

  # -- Message Dispatch --

  defp handle_message(type_id, payload, socket, state) do
    case MessageTypes.decode_message(type_id, payload) do
      {:ok, message} ->
        dispatch(message, socket, state)

      {:error, reason} ->
        Logger.warning("ESPHome client #{state.peer} decode error for type #{type_id}: #{inspect(reason)}")
        {:ok, state}
    end
  end

  # -- Core protocol handlers --

  defp dispatch(%Protos.HelloRequest{} = req, socket, state) do
    Logger.info("ESPHome client #{state.peer} hello: client_info=#{inspect(req.client_info)}")

    response = %Protos.HelloResponse{
      api_version_major: DeviceConfig.api_version_major(),
      api_version_minor: DeviceConfig.api_version_minor(),
      server_info: DeviceConfig.server_info(state.device_config),
      name: state.device_config.name
    }

    send_message(response, socket)
    {:ok, state}
  end

  defp dispatch(%Protos.AuthenticationRequest{}, socket, state) do
    Logger.info("ESPHome client #{state.peer} authentication accepted (no password required)")

    response = %Protos.AuthenticationResponse{invalid_password: false}
    send_message(response, socket)
    {:ok, state}
  end

  defp dispatch(%Protos.PingRequest{}, socket, state) do
    send_message(%Protos.PingResponse{}, socket)
    {:ok, state}
  end

  defp dispatch(%Protos.DeviceInfoRequest{}, socket, state) do
    serial_proxies = Server.serial_proxies()
    response = DeviceConfig.to_device_info_response(state.device_config, serial_proxies)
    Logger.info("ESPHome client #{state.peer} device info requested (name=#{response.name}, #{length(serial_proxies)} serial proxies)")
    send_message(response, socket)
    {:ok, state}
  end

  defp dispatch(%Protos.ListEntitiesRequest{}, socket, state) do
    Logger.info("ESPHome client #{state.peer} list entities requested (0 entities)")
    send_message(%Protos.ListEntitiesDoneResponse{}, socket)
    {:ok, state}
  end

  defp dispatch(%Protos.SubscribeStatesRequest{}, _socket, state) do
    Logger.info("ESPHome client #{state.peer} subscribed to states")
    {:ok, state}
  end

  defp dispatch(%Protos.SubscribeLogsRequest{} = req, _socket, state) do
    Logger.info("ESPHome client #{state.peer} subscribed to logs (level=#{req.level})")
    {:ok, state}
  end

  defp dispatch(%Protos.SubscribeHomeassistantServicesRequest{}, _socket, state) do
    Logger.info("ESPHome client #{state.peer} subscribed to HA services")
    {:ok, state}
  end

  defp dispatch(%Protos.SubscribeHomeAssistantStatesRequest{}, _socket, state) do
    Logger.info("ESPHome client #{state.peer} subscribed to HA states")
    {:ok, state}
  end

  defp dispatch(%Protos.DisconnectRequest{}, socket, state) do
    Logger.info("ESPHome client #{state.peer} requested disconnect")
    send_message(%Protos.DisconnectResponse{}, socket)
    {:close, state}
  end

  defp dispatch(%Protos.GetTimeRequest{}, socket, state) do
    epoch = System.os_time(:second) |> Bitwise.band(0xFFFFFFFF)

    response = %Protos.GetTimeResponse{
      epoch_seconds: epoch
    }

    send_message(response, socket)
    {:ok, state}
  end

  # -- Serial Proxy handlers --

  defp dispatch(%Protos.SerialProxyConfigureRequest{} = req, _socket, state) do
    instance = req.instance

    case Map.fetch(state.instance_map, instance) do
      {:ok, %{path: path, friendly_name: friendly_name}} ->
        opts = [
          speed: if(req.baudrate > 0, do: req.baudrate, else: 9600),
          data_bits: if(req.data_size > 0, do: req.data_size, else: 8),
          stop_bits: if(req.stop_bits > 0, do: req.stop_bits, else: 1),
          parity: proto_parity_to_atom(req.parity),
          flow_control: if(req.flow_control, do: :hardware, else: :none),
          friendly_name: friendly_name
        ]

        # Close if already open from a previous configure
        if Map.has_key?(state.opened_ports, instance) do
          UART.close(path)
        end

        case UART.open(path, opts) do
          {:ok, _pid} ->
            Phoenix.PubSub.subscribe(@pubsub, "uart:#{friendly_name}")
            Logger.info("ESPHome client #{state.peer} configured serial proxy #{instance} (#{friendly_name} @ #{path}, #{opts[:speed]} baud)")
            new_opened = Map.put(state.opened_ports, instance, path)
            {:ok, %{state | opened_ports: new_opened}}

          {:error, reason} ->
            Logger.warning("ESPHome client #{state.peer} failed to open serial proxy #{instance} (#{path}): #{inspect(reason)}")
            {:ok, state}
        end

      :error ->
        Logger.warning("ESPHome client #{state.peer} serial proxy configure for unknown instance #{instance}")
        {:ok, state}
    end
  end

  defp dispatch(%Protos.SerialProxyWriteRequest{} = req, _socket, state) do
    instance = req.instance

    case Map.fetch(state.opened_ports, instance) do
      {:ok, path} ->
        case UART.write(path, req.data) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("ESPHome client #{state.peer} serial proxy write failed for instance #{instance}: #{inspect(reason)}")
        end

      :error ->
        Logger.warning("ESPHome client #{state.peer} serial proxy write for unopened instance #{instance}")
    end

    {:ok, state}
  end

  defp dispatch(%Protos.SerialProxySetModemPinsRequest{} = req, _socket, state) do
    Logger.info("ESPHome client #{state.peer} serial proxy set modem pins instance #{req.instance} (RTS=#{req.rts}, DTR=#{req.dtr}) -- not implemented")
    {:ok, state}
  end

  defp dispatch(%Protos.SerialProxyGetModemPinsRequest{} = req, socket, state) do
    Logger.info("ESPHome client #{state.peer} serial proxy get modem pins instance #{req.instance} -- not implemented")

    response = %Protos.SerialProxyGetModemPinsResponse{
      instance: req.instance,
      rts: false,
      dtr: false
    }

    send_message(response, socket)
    {:ok, state}
  end

  defp dispatch(%Protos.SerialProxyRequest{} = req, _socket, state) do
    Logger.info("ESPHome client #{state.peer} serial proxy request instance #{req.instance} type #{inspect(req.type)}")
    {:ok, state}
  end

  # -- Z-Wave Proxy handlers --

  defp dispatch(%Protos.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_SUBSCRIBE}, socket, state) do
    case ZWave.subscribe(self()) do
      {:ok, home_id_bytes} ->
        Logger.info("ESPHome client #{state.peer} subscribed to Z-Wave proxy")

        if home_id_bytes != <<0, 0, 0, 0>> do
          notify = %Protos.ZWaveProxyRequest{
            type: :ZWAVE_PROXY_REQUEST_TYPE_HOME_ID_CHANGE,
            data: home_id_bytes
          }

          send_message(notify, socket)
        end

        {:ok, %{state | zwave_subscribed: true}}

      {:error, reason} ->
        Logger.warning("ESPHome client #{state.peer} Z-Wave subscribe failed: #{inspect(reason)}")
        {:ok, state}
    end
  end

  defp dispatch(%Protos.ZWaveProxyRequest{type: :ZWAVE_PROXY_REQUEST_TYPE_UNSUBSCRIBE}, _socket, state) do
    ZWave.unsubscribe(self())
    Logger.info("ESPHome client #{state.peer} unsubscribed from Z-Wave proxy")
    {:ok, %{state | zwave_subscribed: false}}
  end

  defp dispatch(%Protos.ZWaveProxyRequest{} = req, _socket, state) do
    Logger.debug("ESPHome client #{state.peer} unhandled Z-Wave proxy request type: #{inspect(req.type)}")
    {:ok, state}
  end

  defp dispatch(%Protos.ZWaveProxyFrame{} = frame, _socket, state) do
    case ZWave.send_frame(frame.data) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("ESPHome client #{state.peer} Z-Wave send_frame failed: #{inspect(reason)}")
    end

    {:ok, state}
  end

  # -- Catch-all --

  defp dispatch(unknown, _socket, state) do
    Logger.debug("ESPHome unhandled message: #{inspect(unknown.__struct__)}")
    {:ok, state}
  end

  # -- Port Cleanup --

  defp close_all_ports(state) do
    if state.zwave_subscribed do
      ZWave.unsubscribe(self())
    end

    Enum.each(state.opened_ports, fn {instance, path} ->
      case UART.close(path) do
        :ok ->
          Logger.info("ESPHome client #{state.peer} closed serial proxy #{instance} (#{path})")

        {:error, reason} ->
          Logger.warning("ESPHome client #{state.peer} failed to close serial proxy #{instance} (#{path}): #{inspect(reason)}")
      end
    end)
  end

  # -- Helpers --

  defp find_instance_for_friendly_name(state, friendly_name) do
    Enum.find_value(state.instance_map, fn {index, info} ->
      if info.friendly_name == friendly_name, do: index
    end)
  end

  defp proto_parity_to_atom(:SERIAL_PROXY_PARITY_NONE), do: :none
  defp proto_parity_to_atom(:SERIAL_PROXY_PARITY_EVEN), do: :even
  defp proto_parity_to_atom(:SERIAL_PROXY_PARITY_ODD), do: :odd
  defp proto_parity_to_atom(_), do: :none

  defp peer_label(socket) do
    case ThousandIsland.Socket.peername(socket) do
      {:ok, {addr, port}} ->
        "#{:inet.ntoa(addr)}:#{port}"

      _ ->
        "unknown"
    end
  end

  defp send_message(message, socket) do
    case MessageTypes.encode_message(message) do
      {:ok, frame} ->
        ThousandIsland.Socket.send(socket, frame)

      {:error, reason} ->
        Logger.warning("ESPHome encode error: #{inspect(reason)}")
    end
  end
end
