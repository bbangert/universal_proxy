defmodule UniversalProxy.TuyaBeaconMesh.ControlTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaBeaconMesh.{Control, Crypto, Dp, P2}

  @local_key "abcdefghijklmnop"
  @beacon_key "00112233445566778899aabbccddeeff"
  @node 2
  @sn 42

  test "phone_addr and min_send_ms are the hardware-proven constants" do
    assert Control.phone_addr() == 0x8001
    assert Control.min_send_ms() == 3_000
  end

  test "friendly_dps maps on/mode/colour/brightness/temp" do
    assert {:ok, dps} =
             Control.friendly_dps(
               on: true,
               mode: :colour,
               colour: {300, 100, 100},
               brightness: 500,
               temp: 200
             )

    assert dps == [
             {1, :bool, true},
             {2, :enum, 1},
             {11, :raw, <<300::16-big, 100, 100>>},
             {3, :value, 500},
             {4, :value, 200}
           ]

    assert {:error, :no_dps} = Control.friendly_dps([])
    assert {:error, {:bad_mode, :disco}} = Control.friendly_dps(mode: :disco)
  end

  test "set builds a phone-sourced unicast dp_set_ack with bumped send_ms" do
    assert {:ok, {frame, send_ms, _window, :dp_report}} =
             Control.set(@node, @sn, [on: false], @local_key, @beacon_key, ack: true)

    assert send_ms == 3_000
    assert byte_size(frame) == 26

    # Source 0x8001, dest node 2, subCmd 0x06 (ack).
    <<_hdr, src::binary-2, dst::binary-2, sn::16-big, sub_cmd, _rest::binary>> = frame
    assert src == <<0x80, 0x01>>
    assert dst == <<0x00, 0x02>>
    assert sn == @sn
    assert sub_cmd == 0x06
  end

  test "ping and reset use phone source and localKey/beaconKey" do
    {ping_frame, send_ms, _w, :ping_reply} = Control.ping(@node, @sn, @local_key, @beacon_key)
    assert send_ms >= 3_000
    <<_, src::binary-2, dst::binary-2, _::binary>> = ping_frame
    assert src == <<0x80, 0x01>>
    assert dst == <<0x00, 0x02>>

    {reset_frame, _, _, :reset_ack} = Control.reset(@node, @sn + 1, @local_key, @beacon_key)
    <<_, rsrc::binary-2, _::binary>> = reset_frame
    assert rsrc == <<0x80, 0x01>>
  end

  test "group_set addresses FFgg and keys with beaconKey/beaconKey" do
    assert {:ok, {frame, send_ms, _w, :none}} =
             Control.group_set(1, @sn, [on: true], @beacon_key)

    assert send_ms >= 3_000
    <<_, src::binary-2, dst::binary-2, _::binary>> = frame
    assert src == <<0x80, 0x01>>
    assert dst == <<0xFF, 0x01>>
  end

  # Device frames go phone-bound; for a host-built control frame we only
  # need the header fields. Re-encode via the same builders to prove the
  # DP payload is what friendly_dps produced.
  test "set payload matches Dp.encode of friendly_dps" do
    {:ok, dps} = Control.friendly_dps(on: true, mode: :white)
    {:ok, tlv} = Dp.encode(dps)
    {expected, _, _, _} = P2.dp_set(0x8001, @node, @sn, tlv, @local_key, @beacon_key)

    {:ok, {actual, _, _, _}} =
      Control.set(@node, @sn, [on: true, mode: :white], @local_key, @beacon_key)

    # Same ciphertext once send_ms bump is ignored — compare after normalizing hop bits.
    assert P2.normalize(actual) == P2.normalize(expected)
    assert Crypto.key_bytes(@local_key) == "abcdefghijklmnop"
  end
end
