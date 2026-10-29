defmodule UniversalProxy.TuyaBeaconMesh.CarrierTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaBeaconMesh.Carrier

  @capture "test/fixtures/tuya_beacon_mesh/p2_frames_2026-10-25.json"
           |> File.read!()
           |> Jason.decode!()

  test "ad_bytes matches the bulbs' own layout and fills 31 bytes" do
    frame = @capture["frames"] |> hd() |> Map.fetch!("frame") |> Base.decode16!()
    ad = Carrier.ad_bytes(frame)
    assert byte_size(ad) == 31
    assert <<0x02, 0x01, 0x06, 0x1B, 0x03, ^frame::binary>> = ad
  end

  test "frames extracts the AD 0x03 payload and round-trips ad_bytes" do
    for f <- @capture["frames"] do
      frame = Base.decode16!(f["frame"])
      assert Carrier.frames(Carrier.ad_bytes(frame)) == [frame]
    end
  end

  test "frames skips other AD types, wrong-length 0x03 lists and padding" do
    frame = :binary.copy(<<0xAB>>, 26)
    data = <<2, 1, 6, 5, 3, 1, 2, 3, 4, 0, 0>> <> <<27, 3>> <> frame <> <<3, 0x19, 0, 0>>
    assert Carrier.frames(data) == [frame]
  end

  test "frames stops at a truncated element" do
    assert Carrier.frames(<<27, 3, 1, 2, 3>>) == []
    assert Carrier.frames(<<>>) == []
  end
end
