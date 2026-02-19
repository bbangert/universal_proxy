defmodule UniversalProxy.ESPHome.DeviceConfig do
  @moduledoc """
  Data structure representing the ESPHome device identity.

  Holds all the fields reported in a `DeviceInfoResponse` when a client
  queries this device over the ESPHome Native API, plus the TCP port
  the server listens on.
  """

  alias UniversalProxy.ESPHome.ZWave
  alias UniversalProxy.Protos.DeviceInfoResponse

  @default_port 6053
  @api_version_major 1
  @api_version_minor 10

  @type t :: %__MODULE__{
          name: String.t(),
          friendly_name: String.t(),
          mac_address: String.t(),
          esphome_version: String.t(),
          compilation_time: String.t(),
          model: String.t(),
          manufacturer: String.t(),
          suggested_area: String.t(),
          project_name: String.t(),
          project_version: String.t(),
          port: non_neg_integer()
        }

  defstruct name: "universal-proxy",
            friendly_name: "Universal Proxy",
            mac_address: "00:00:00:00:00:00",
            esphome_version: "2026.1.0",
            compilation_time: "",
            model: "Universal Proxy",
            manufacturer: "UniversalProxy",
            suggested_area: "",
            project_name: "universal_proxy",
            project_version: "0.1.0",
            port: @default_port

  @doc """
  Build a new `%DeviceConfig{}` from keyword options.

  Any key not provided uses the default value. If `:mac_address` is not
  provided, the hardware address of the `eth0` interface is detected
  automatically at runtime.

  ## Examples

      DeviceConfig.new(name: "my-device", port: 6054)

  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :mac_address, &detect_mac_address/0)
    struct!(__MODULE__, opts)
  end

  @doc """
  Returns the API version major number this server advertises.
  """
  @spec api_version_major() :: non_neg_integer()
  def api_version_major, do: @api_version_major

  @doc """
  Returns the API version minor number this server advertises.
  """
  @spec api_version_minor() :: non_neg_integer()
  def api_version_minor, do: @api_version_minor

  @doc """
  Convert this config to a `DeviceInfoResponse` protobuf struct.

  Accepts an optional list of `%SerialProxyInfo{}` structs to populate
  the `serial_proxies` field in the response.
  """
  @spec to_device_info_response(t(), [map()]) :: DeviceInfoResponse.t()
  def to_device_info_response(%__MODULE__{} = config, serial_proxies \\ []) do
    %DeviceInfoResponse{
      name: config.name,
      friendly_name: config.friendly_name,
      mac_address: config.mac_address,
      esphome_version: config.esphome_version,
      compilation_time: config.compilation_time,
      model: config.model,
      manufacturer: config.manufacturer,
      suggested_area: config.suggested_area,
      project_name: config.project_name,
      project_version: config.project_version,
      webserver_port: 0,
      has_deep_sleep: false,
      uses_password: false,
      api_encryption_supported: false,
      zwave_proxy_feature_flags: zwave_feature_flags(),
      zwave_home_id: zwave_home_id(),
      serial_proxies: serial_proxies
    }
  end

  @doc """
  Build the server info string used in `HelloResponse`.
  """
  @spec server_info(t()) :: String.t()
  def server_info(%__MODULE__{} = config) do
    "UniversalProxy #{config.project_version} (#{config.esphome_version})"
  end

  @doc """
  Build an mDNS service map suitable for `MdnsLite.add_mdns_service/1`.

  Advertises the `_esphomelib._tcp` service with TXT records containing
  the device identity fields that ESPHome clients use for discovery.
  """
  @spec to_mdns_service(t()) :: map()
  def to_mdns_service(%__MODULE__{} = config) do
    txt =
      [
        {"mac", config.mac_address},
        {"version", config.esphome_version},
        {"friendly_name", config.friendly_name},
        {"project_name", config.project_name},
        {"project_version", config.project_version}
      ]
      |> Enum.reject(fn {_k, v} -> v == "" or is_nil(v) end)
      |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)

    %{
      id: :esphomelib,
      protocol: "esphomelib",
      transport: "tcp",
      port: config.port,
      txt_payload: txt
    }
  end

  @doc """
  Detect the MAC address of the `eth0` network interface.

  Returns the hardware address as an `"AA:BB:CC:DD:EE:FF"` string,
  or `"00:00:00:00:00:00"` if the interface is not found.
  """
  @spec detect_mac_address() :: String.t()
  def detect_mac_address do
    with {:ok, ifaddrs} <- :inet.getifaddrs(),
         {_name, opts} <- List.keyfind(ifaddrs, ~c"eth0", 0),
         [_ | _] = hwaddr <- Keyword.get(opts, :hwaddr) do
      hwaddr
      |> Enum.map(fn byte ->
        byte |> Integer.to_string(16) |> String.pad_leading(2, "0")
      end)
      |> Enum.join(":")
      |> String.upcase()
    else
      _ -> "00:00:00:00:00:00"
    end
  end

  # Bit 0 = FEATURE_ZWAVE_PROXY_ENABLED
  defp zwave_feature_flags do
    if ZWave.available?(), do: 1, else: 0
  rescue
    _ -> 0
  end

  defp zwave_home_id do
    ZWave.home_id()
  rescue
    _ -> 0
  end
end
