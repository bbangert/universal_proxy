defmodule UniversalProxy.ESPHome.MessageTypes do
  @moduledoc """
  Registry mapping ESPHome Native API message type IDs to their
  protobuf modules and back.

  Message type IDs are defined via `option (id) = N` in `api.proto`.
  All modules live under `UniversalProxy.Protos`.
  """

  alias UniversalProxy.Protos

  @message_types %{
    1 => Protos.HelloRequest,
    2 => Protos.HelloResponse,
    3 => Protos.AuthenticationRequest,
    4 => Protos.AuthenticationResponse,
    5 => Protos.DisconnectRequest,
    6 => Protos.DisconnectResponse,
    7 => Protos.PingRequest,
    8 => Protos.PingResponse,
    9 => Protos.DeviceInfoRequest,
    10 => Protos.DeviceInfoResponse,
    11 => Protos.ListEntitiesRequest,
    12 => Protos.ListEntitiesBinarySensorResponse,
    13 => Protos.ListEntitiesCoverResponse,
    14 => Protos.ListEntitiesFanResponse,
    15 => Protos.ListEntitiesLightResponse,
    16 => Protos.ListEntitiesSensorResponse,
    17 => Protos.ListEntitiesSwitchResponse,
    18 => Protos.ListEntitiesTextSensorResponse,
    19 => Protos.ListEntitiesDoneResponse,
    20 => Protos.SubscribeStatesRequest,
    21 => Protos.BinarySensorStateResponse,
    22 => Protos.CoverStateResponse,
    23 => Protos.FanStateResponse,
    24 => Protos.LightStateResponse,
    25 => Protos.SensorStateResponse,
    26 => Protos.SwitchStateResponse,
    27 => Protos.TextSensorStateResponse,
    28 => Protos.SubscribeLogsRequest,
    29 => Protos.SubscribeLogsResponse,
    30 => Protos.CoverCommandRequest,
    31 => Protos.FanCommandRequest,
    32 => Protos.LightCommandRequest,
    33 => Protos.SwitchCommandRequest,
    34 => Protos.SubscribeHomeassistantServicesRequest,
    35 => Protos.HomeassistantActionRequest,
    36 => Protos.GetTimeRequest,
    37 => Protos.GetTimeResponse,
    38 => Protos.SubscribeHomeAssistantStatesRequest,
    39 => Protos.SubscribeHomeAssistantStateResponse,
    40 => Protos.HomeAssistantStateResponse,
    41 => Protos.ListEntitiesServicesResponse,
    42 => Protos.ExecuteServiceRequest,
    43 => Protos.ListEntitiesCameraResponse,
    44 => Protos.CameraImageResponse,
    45 => Protos.CameraImageRequest,
    46 => Protos.ListEntitiesClimateResponse,
    47 => Protos.ClimateStateResponse,
    48 => Protos.ClimateCommandRequest,
    49 => Protos.ListEntitiesNumberResponse,
    50 => Protos.NumberStateResponse,
    51 => Protos.NumberCommandRequest,
    52 => Protos.ListEntitiesSelectResponse,
    53 => Protos.SelectStateResponse,
    54 => Protos.SelectCommandRequest,
    55 => Protos.ListEntitiesSirenResponse,
    56 => Protos.SirenStateResponse,
    57 => Protos.SirenCommandRequest,
    58 => Protos.ListEntitiesLockResponse,
    59 => Protos.LockStateResponse,
    60 => Protos.LockCommandRequest,
    61 => Protos.ListEntitiesButtonResponse,
    62 => Protos.ButtonCommandRequest,
    63 => Protos.ListEntitiesMediaPlayerResponse,
    64 => Protos.MediaPlayerStateResponse,
    65 => Protos.MediaPlayerCommandRequest,
    66 => Protos.SubscribeBluetoothLEAdvertisementsRequest,
    68 => Protos.BluetoothDeviceRequest,
    69 => Protos.BluetoothDeviceConnectionResponse,
    70 => Protos.BluetoothGATTGetServicesRequest,
    71 => Protos.BluetoothGATTGetServicesResponse,
    72 => Protos.BluetoothGATTGetServicesDoneResponse,
    73 => Protos.BluetoothGATTReadRequest,
    74 => Protos.BluetoothGATTReadResponse,
    75 => Protos.BluetoothGATTWriteRequest,
    76 => Protos.BluetoothGATTReadDescriptorRequest,
    77 => Protos.BluetoothGATTWriteDescriptorRequest,
    78 => Protos.BluetoothGATTNotifyRequest,
    79 => Protos.BluetoothGATTNotifyDataResponse,
    80 => Protos.SubscribeBluetoothConnectionsFreeRequest,
    81 => Protos.BluetoothConnectionsFreeResponse,
    82 => Protos.BluetoothGATTErrorResponse,
    83 => Protos.BluetoothGATTWriteResponse,
    84 => Protos.BluetoothGATTNotifyResponse,
    85 => Protos.BluetoothDevicePairingResponse,
    86 => Protos.BluetoothDeviceUnpairingResponse,
    87 => Protos.UnsubscribeBluetoothLEAdvertisementsRequest,
    88 => Protos.BluetoothDeviceClearCacheResponse,
    89 => Protos.SubscribeVoiceAssistantRequest,
    90 => Protos.VoiceAssistantRequest,
    91 => Protos.VoiceAssistantResponse,
    92 => Protos.VoiceAssistantEventResponse,
    93 => Protos.BluetoothLERawAdvertisementsResponse,
    94 => Protos.ListEntitiesAlarmControlPanelResponse,
    95 => Protos.AlarmControlPanelStateResponse,
    96 => Protos.AlarmControlPanelCommandRequest,
    97 => Protos.ListEntitiesTextResponse,
    98 => Protos.TextStateResponse,
    99 => Protos.TextCommandRequest,
    100 => Protos.ListEntitiesDateResponse,
    101 => Protos.DateStateResponse,
    102 => Protos.DateCommandRequest,
    103 => Protos.ListEntitiesTimeResponse,
    104 => Protos.TimeStateResponse,
    105 => Protos.TimeCommandRequest,
    106 => Protos.VoiceAssistantAudio,
    107 => Protos.ListEntitiesEventResponse,
    108 => Protos.EventResponse,
    109 => Protos.ListEntitiesValveResponse,
    110 => Protos.ValveStateResponse,
    111 => Protos.ValveCommandRequest,
    112 => Protos.ListEntitiesDateTimeResponse,
    113 => Protos.DateTimeStateResponse,
    114 => Protos.DateTimeCommandRequest,
    115 => Protos.VoiceAssistantTimerEventResponse,
    116 => Protos.ListEntitiesUpdateResponse,
    117 => Protos.UpdateStateResponse,
    118 => Protos.UpdateCommandRequest,
    119 => Protos.VoiceAssistantAnnounceRequest,
    120 => Protos.VoiceAssistantAnnounceFinished,
    121 => Protos.VoiceAssistantConfigurationRequest,
    122 => Protos.VoiceAssistantConfigurationResponse,
    123 => Protos.VoiceAssistantSetConfiguration,
    124 => Protos.NoiseEncryptionSetKeyRequest,
    125 => Protos.NoiseEncryptionSetKeyResponse,
    126 => Protos.BluetoothScannerStateResponse,
    127 => Protos.BluetoothScannerSetModeRequest,
    128 => Protos.ZWaveProxyFrame,
    129 => Protos.ZWaveProxyRequest,
    130 => Protos.HomeassistantActionResponse,
    131 => Protos.ExecuteServiceResponse,
    132 => Protos.ListEntitiesWaterHeaterResponse,
    133 => Protos.WaterHeaterStateResponse,
    134 => Protos.WaterHeaterCommandRequest,
    135 => Protos.ListEntitiesInfraredResponse,
    136 => Protos.InfraredRFTransmitRawTimingsRequest,
    137 => Protos.InfraredRFReceiveEvent,
    # Serial Proxy messages
    138 => Protos.SerialProxyConfigureRequest,
    139 => Protos.SerialProxyDataReceived,
    140 => Protos.SerialProxyWriteRequest,
    141 => Protos.SerialProxySetModemPinsRequest,
    142 => Protos.SerialProxyGetModemPinsRequest,
    143 => Protos.SerialProxyGetModemPinsResponse,
    144 => Protos.SerialProxyRequest
  }

  @reverse_types Map.new(@message_types, fn {id, mod} -> {mod, id} end)

  @doc """
  Return the protobuf module for a given message type ID.

  Returns `{:ok, module}` or `:error`.
  """
  @spec module_for_id(non_neg_integer()) :: {:ok, module()} | :error
  def module_for_id(id) do
    Map.fetch(@message_types, id)
  end

  @doc """
  Return the message type ID for a given protobuf module.

  Returns `{:ok, id}` or `:error`.
  """
  @spec id_for_module(module()) :: {:ok, non_neg_integer()} | :error
  def id_for_module(module) do
    Map.fetch(@reverse_types, module)
  end

  @doc """
  Decode a protobuf binary given its message type ID.

  Returns `{:ok, struct}` or `{:error, reason}`.
  """
  @spec decode_message(non_neg_integer(), binary()) :: {:ok, struct()} | {:error, term()}
  def decode_message(type_id, payload) do
    case module_for_id(type_id) do
      {:ok, module} ->
        {:ok, module.decode(payload)}

      :error ->
        {:error, {:unknown_message_type, type_id}}
    end
  rescue
    e -> {:error, {:decode_failed, e}}
  end

  @doc """
  Encode a protobuf struct to its wire frame (indicator + varints + payload).

  Looks up the message type ID from the struct's module and delegates
  to `Protocol.encode_frame/2`.
  """
  @spec encode_message(struct()) :: {:ok, binary()} | {:error, term()}
  def encode_message(%mod{} = message) do
    case id_for_module(mod) do
      {:ok, type_id} ->
        payload = mod.encode(message)
        frame = UniversalProxy.ESPHome.Protocol.encode_frame(type_id, payload)
        {:ok, frame}

      :error ->
        {:error, {:unknown_module, mod}}
    end
  end
end
