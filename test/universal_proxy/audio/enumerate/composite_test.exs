defmodule UniversalProxy.Audio.Enumerate.CompositeTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Audio.Enumerate.Composite

  defmodule AlsaStub do
    @moduledoc false
    def safe do
      %{
        {"1-1.3", 0x0BDA, 0x4E27} => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "USB SPDIF Adapter",
          usb_port: "1-1.3"
        }
      }
    end
  end

  defmodule HeadsetStub do
    @moduledoc false
    def safe do
      %{
        {"AA:BB:CC:DD:EE:FF", nil, nil} => %{
          card_index: nil,
          alsa_device: "bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp",
          card_name: "WH-1000XM4",
          usb_port: nil
        }
      }
    end
  end

  defmodule EmptyStub do
    @moduledoc false
    def safe, do: %{}
  end

  defmodule RaisingStub do
    @moduledoc false
    def safe, do: raise("boom")
  end

  describe "safe/1" do
    test "unions ALSA cards and connected headsets without key collision" do
      out = Composite.safe([AlsaStub, HeadsetStub])

      assert map_size(out) == 2
      assert Map.has_key?(out, {"1-1.3", 0x0BDA, 0x4E27})
      assert Map.has_key?(out, {"AA:BB:CC:DD:EE:FF", nil, nil})
      assert out[{"AA:BB:CC:DD:EE:FF", nil, nil}].alsa_device =~ "bluealsa:DEV="
    end

    test "degrades to just ALSA cards when the headset source is empty" do
      assert Composite.safe([AlsaStub, EmptyStub]) == AlsaStub.safe()
    end

    test "default sources (real Enumerate + AudioSink) never raise and return a map" do
      # On CI neither source finds anything, but the call must be inert.
      assert is_map(Composite.safe())
    end
  end

  describe "real default safe/0" do
    test "is the union of the two configured sources" do
      # Wiring sanity: the production path is Enumerate + AudioSink.
      assert Composite.safe() ==
               Map.merge(
                 UniversalProxy.Audio.Enumerate.safe(),
                 UniversalProxy.Bluetooth.AudioSink.safe()
               )
    end
  end

  # A raising source would crash the whole refresh; document that Composite
  # relies on each source being individually `safe` (rescues to %{}). This
  # asserts the contract boundary rather than hiding a bug.
  test "a source that violates the safe contract propagates (not silently swallowed)" do
    assert_raise RuntimeError, fn -> Composite.safe([AlsaStub, RaisingStub]) end
  end
end
