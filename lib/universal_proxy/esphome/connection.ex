defmodule UniversalProxy.ESPHome.Connection do
  @moduledoc """
  ThousandIsland handler for a single ESPHome Native API client connection.

  Each accepted TCP connection gets its own handler process managed by
  ThousandIsland. It buffers incoming data, decodes plaintext protocol
  frames, and dispatches protobuf messages to the appropriate handler.
  """

  use ThousandIsland.Handler

  require Logger

  alias UniversalProxy.ESPHome.{DeviceConfig, MessageTypes, Protocol, Server}
  alias UniversalProxy.Protos

  @impl ThousandIsland.Handler
  def handle_connection(socket, _state) do
    device_config = Server.get_config()
    Server.register_connection(self())
    peer = peer_label(socket)

    Logger.info("ESPHome client connected from #{peer}")

    {:continue, %{buffer: <<>>, device_config: device_config, peer: peer}}
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    new_buffer = state.buffer <> data
    state = %{state | buffer: new_buffer}

    case process_buffer(socket, state) do
      {:ok, state} ->
        {:continue, state}

      {:close, state} ->
        {:close, state}

      {:error, reason, state} ->
        {:error, reason, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_close(_socket, state) do
    Logger.info("ESPHome client #{state.peer} disconnected (closed)")
    :ok
  end

  @impl ThousandIsland.Handler
  def handle_error(reason, _socket, state) do
    Logger.warning("ESPHome client #{state.peer} connection error: #{inspect(reason)}")
    :ok
  end

  @impl ThousandIsland.Handler
  def handle_timeout(_socket, state) do
    Logger.warning("ESPHome client #{state.peer} timed out")
    :ok
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
    response = DeviceConfig.to_device_info_response(state.device_config)
    Logger.info("ESPHome client #{state.peer} device info requested (name=#{response.name})")
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

  defp dispatch(unknown, _socket, state) do
    Logger.debug("ESPHome unhandled message: #{inspect(unknown.__struct__)}")
    {:ok, state}
  end

  # -- Peer Helpers --

  defp peer_label(socket) do
    case ThousandIsland.Socket.peername(socket) do
      {:ok, {addr, port}} ->
        "#{:inet.ntoa(addr)}:#{port}"

      _ ->
        "unknown"
    end
  end

  # -- Send Helpers --

  defp send_message(message, socket) do
    case MessageTypes.encode_message(message) do
      {:ok, frame} ->
        ThousandIsland.Socket.send(socket, frame)

      {:error, reason} ->
        Logger.warning("ESPHome encode error: #{inspect(reason)}")
    end
  end
end
