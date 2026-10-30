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

  # Undoes P2.build with the given key pair: XOR-unmask, check the frame
  # CRC, XXTEA-decrypt, check the payload CRC. Swapped keys fail a CRC.
  defp open_frame(frame, key, mask) do
    <<hdr, head::binary-6, sub_cmd, payload_crc, masked::binary-16, frame_crc>> = frame
    cipher = :crypto.exor(masked, Crypto.key_bytes(mask))

    assert Crypto.crc8(<<Bitwise.band(hdr, 0xFC)>> <> head <> <<sub_cmd, payload_crc>> <> cipher) ==
             frame_crc

    payload = Crypto.xxtea_decrypt(cipher, Crypto.key_bytes(key))
    assert Crypto.crc8(payload) == payload_crc
    {sub_cmd, payload}
  end

  defp pad(bin), do: bin <> :binary.copy(<<0>>, 16 - byte_size(bin))

  test "ping and reset use phone source and localKey/beaconKey" do
    {ping_frame, send_ms, _w, :ping_reply} = Control.ping(@node, @sn, @local_key, @beacon_key)
    assert send_ms >= 3_000
    <<_, src::binary-2, dst::binary-2, _::binary>> = ping_frame
    assert src == <<0x80, 0x01>>
    assert dst == <<0x00, 0x02>>
    assert open_frame(ping_frame, @local_key, @beacon_key) == {0x01, pad(<<0x01>>)}

    {reset_frame, _, _, :reset_ack} = Control.reset(@node, @sn + 1, @local_key, @beacon_key)
    <<_, rsrc::binary-2, _::binary>> = reset_frame
    assert rsrc == <<0x80, 0x01>>
    assert open_frame(reset_frame, @local_key, @beacon_key) == {0x01, pad(<<0x02>>)}
  end

  test "set encrypts with the localKey and masks with the beaconKey" do
    {:ok, {frame, _, _, :none}} = Control.set(@node, @sn, [on: true], @local_key, @beacon_key)
    {:ok, tlv} = Dp.encode([{1, :bool, true}])
    assert open_frame(frame, @local_key, @beacon_key) == {0x05, pad(tlv)}
  end

  test "group_set addresses FFgg and keys with beaconKey/beaconKey" do
    assert {:ok, {frame, send_ms, _w, :none}} =
             Control.group_set(1, @sn, [on: true], @beacon_key)

    assert send_ms >= 3_000
    <<_, src::binary-2, dst::binary-2, _::binary>> = frame
    assert src == <<0x80, 0x01>>
    assert dst == <<0xFF, 0x01>>
    {:ok, tlv} = Dp.encode([{1, :bool, true}])
    assert open_frame(frame, @beacon_key, @beacon_key) == {0x05, pad(tlv)}

    assert {:error, {:bad_group, 256}} = Control.group_set(256, @sn, [on: true], @beacon_key)
    assert {:error, {:bad_group, "1"}} = Control.group_set("1", @sn, [on: true], @beacon_key)
  end

  test "friendly_dps bounds" do
    for bad <- [
          brightness: 9,
          brightness: 1001,
          temp: 1001,
          temp: -1,
          colour: {360, 0, 0},
          colour: {0, 101, 0},
          colour: {0, 0, 101},
          colour: {1, 2},
          on: 1,
          mode: 256,
          volume: 3
        ] do
      assert {:error, _} = Control.friendly_dps([bad]), "accepted #{inspect(bad)}"
    end

    assert {:ok, [{2, :enum, 3}]} = Control.friendly_dps(mode: 3)
    assert {:ok, [{1, :bool, false}]} = Control.friendly_dps(%{on: false})

    assert {:ok, [{3, :value, 10}, {3, :value, 1000}]} =
             Control.friendly_dps(brightness: 10, brightness: 1000)
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
  end
end
