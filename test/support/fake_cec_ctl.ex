defmodule UniversalProxy.Cec.FakeCtl do
  @moduledoc """
  Recording stand-in for `UniversalProxy.Cec.Ctl`.

  Every `run/2` sends `{:cec_ctl, args}` to the pid registered under
  `:cec_fake_ctl_pid` in the application env (set per test; the Cec tests
  are `async: false`) and answers from a canned table keyed on the message
  flag in `args`. A test can override the output for a flag through the
  `:cec_fake_ctl_outputs` env map (`%{"--standby" => text}`); every output
  goes through `Ctl.check_transmits/1`, as the real `run/2` does.
  """

  alias UniversalProxy.Cec.Ctl

  @behaviour UniversalProxy.Cec.Ctl

  @driver_info """
  Driver Info:
  \tDriver Name                : vc4_hdmi
  \tAdapter Name               : vc4
  \tCapabilities               : 0x0000010e
  \t\tLogical Addresses
  \t\tTransmit
  \t\tPassthrough
  \t\tRemote Control Support
  \tDriver version             : 6.18.33
  \tAvailable Logical Addresses: 1
  \tDRM Connector Info         : card 1, connector 32
  \tPhysical Address           : 1.0.0.0
  \tLogical Address Mask       : 0x0010
  \tCEC Version                : 2.0
  \tOSD Name                   : 'Universal Proxy'
  \tLogical Addresses          : 1 (Allow RC Passthrough)

  \t  Logical Address          : 4 (Playback Device 1)
  \t    Primary Device Type    : Playback
  \t    Logical Address Type   : Playback
  \t    All Device Types       : Playback
  """

  @power_reply """

  Transmit from Playback Device 1 to Audio System (4 to 5):
  GIVE_DEVICE_POWER_STATUS (0x8f)
      Received from Audio System (5):
      REPORT_POWER_STATUS (0x90):
  \tpwr-state: Standby (0x01)
  \tSequence: 3 Tx Timestamp: 10:00:00.000 Rx Timestamp: 10:00:00.120
  """

  @audio_reply """

  Transmit from Playback Device 1 to Audio System (4 to 5):
  GIVE_AUDIO_STATUS (0x71)
      Received from Audio System (5):
      REPORT_AUDIO_STATUS (0x7a):
  \taud-mute-status: Off (0x00)
  \taud-vol-status: 40 (0x28)
  \tSequence: 4 Tx Timestamp: 10:00:01.000 Rx Timestamp: 10:00:01.090
  """

  @impl true
  def run(args, _opts) do
    if pid = Application.get_env(:universal_proxy, :cec_fake_ctl_pid),
      do: send(pid, {:cec_ctl, args})

    overrides = Application.get_env(:universal_proxy, :cec_fake_ctl_outputs, %{})

    out =
      case Enum.find(args, &Map.has_key?(overrides, &1)) do
        nil -> canned(args)
        flag -> Map.fetch!(overrides, flag)
      end

    Ctl.check_transmits(out)
  end

  defp canned(args) do
    cond do
      "--give-device-power-status" in args ->
        @power_reply

      "--give-audio-status" in args ->
        @audio_reply

      "--playback" in args ->
        ""

      length(args) == 2 ->
        @driver_info

      true ->
        "\nTransmit from Playback Device 1 to TV (4 to 0):\nIMAGE_VIEW_ON (0x04)\n\tSequence: 1\n"
    end
  end
end
