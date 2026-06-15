defmodule UniversalProxy.Bluetooth.AudioSinkTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Bluetooth.AudioSink

  describe "from_pcms/1" do
    test "shapes a PCM list into the Audio.Enumerate contract" do
      pcms = [
        %{
          mac: "AA:BB:CC:DD:EE:FF",
          pcm_path: "/org/bluealsa/hci0/dev_AA_BB_CC_DD_EE_FF/a2dpsrc/sink",
          alsa_string: "bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp",
          alias: "WH-1000XM4"
        }
      ]

      assert AudioSink.from_pcms(pcms) == %{
               {"AA:BB:CC:DD:EE:FF", nil, nil} => %{
                 card_index: nil,
                 alsa_device: "bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp",
                 card_name: "WH-1000XM4",
                 usb_port: nil
               }
             }
    end

    test "keys by {mac, nil, nil} so it can't collide with an ALSA card key" do
      %{} = out = AudioSink.from_pcms([pcm("11:22:33:44:55:66")])
      assert [{"11:22:33:44:55:66", nil, nil}] = Map.keys(out)
    end

    test "falls back to the MAC when alias is nil or absent" do
      out = AudioSink.from_pcms([Map.delete(pcm("00:11:22:33:44:55"), :alias)])
      assert %{{"00:11:22:33:44:55", nil, nil} => %{card_name: "00:11:22:33:44:55"}} = out

      out2 = AudioSink.from_pcms([%{pcm("66:77:88:99:AA:BB") | alias: nil}])
      assert %{{"66:77:88:99:AA:BB", nil, nil} => %{card_name: "66:77:88:99:AA:BB"}} = out2
    end

    test "empty list yields an empty map" do
      assert AudioSink.from_pcms([]) == %{}
    end
  end

  describe "safe/0" do
    test "returns %{} when the BlueAlsa client isn't running (off-target/CI)" do
      # UniversalProxy.Bluez.BlueAlsa isn't started in the test app, so pcms/0
      # catches the :exit and returns []; safe/0 must stay inert.
      assert AudioSink.safe() == %{}
    end
  end

  defp pcm(mac) do
    %{
      mac: mac,
      pcm_path: "/org/bluealsa/hci0/dev_#{String.replace(mac, ":", "_")}/a2dpsrc/sink",
      alsa_string: "bluealsa:DEV=#{mac},PROFILE=a2dp",
      alias: "Headset #{mac}"
    }
  end
end
