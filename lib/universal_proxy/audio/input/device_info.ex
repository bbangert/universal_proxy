defmodule UniversalProxy.Audio.Input.DeviceInfo do
  @moduledoc """
  Shared device-identity helpers for the audio-input subsystem.

  `Audio.Input.Server` (the mDNS instance-name suffix) and
  `Audio.Input.Source` (`client/hello.device_info`) both need the device's
  ESPHome node name and network MAC. Keeping one copy here stops the two
  from drifting. Both readers are defensive: a down `ESPHome.ConfigStore`
  degrades to `nil` (an unsuffixed name / no `mac_address` field) rather than
  crashing a registration or a handshake.
  """

  @mac_re ~r/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/

  @doc "The ESPHome node name, or `nil` when the config store is unavailable."
  @spec node_name() :: String.t() | nil
  def node_name do
    UniversalProxy.ESPHome.ConfigStore.current().name
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  @doc """
  The device's normalized (lowercase, colon-separated) network MAC, or `nil`
  when unavailable or all-zero.
  """
  @spec mac_address() :: String.t() | nil
  def mac_address do
    UniversalProxy.ESPHome.ConfigStore.current()
    |> Map.get(:mac_address)
    |> Kernel.||(Espex.DeviceConfig.detect_mac_address())
    |> normalize_mac()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp normalize_mac(mac) when is_binary(mac) do
    mac = mac |> String.trim() |> String.downcase()

    if mac != "00:00:00:00:00:00" and Regex.match?(@mac_re, mac), do: mac
  end

  defp normalize_mac(_mac), do: nil
end
