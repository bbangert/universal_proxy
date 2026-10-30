defmodule UniversalProxy.TuyaBeaconMesh.P2 do
  @moduledoc """
  Beacon v2 ("P2") frames (tuya_beacon_mesh.md §4): the unpaired advert, the
  26-byte request/device frame, the pair frame, and the §4.7 request builders.

  Frame layout (§4.2), both directions:

  | offset | field |
  |---|---|
  | 0 | header: bit 7 = pair flag, bits 6–3 = frame type, bits 1–0 = hop count |
  | 1 | source address (2 bytes) |
  | 3 | destination address (2 bytes) |
  | 5 | sequence number, big-endian |
  | 7 | sub-command |
  | 8 | CRC-8 of the 16-byte plaintext payload |
  | 9 | `XXTEA(payload)` XOR mask (16 bytes) |
  | 25 | CRC-8 of `[hdr & 0xFC]` ‖ bytes 1..24, computed before masking |

  Header bits 1–0 are excluded from both CRCs and are a hop TTL: `build/8`
  sets them to 3 and bulbs relaying a frame decrement them; `normalize/1`
  clears them so relayed copies dedupe.

  Keys (§4.1) are used as-is and passed to `UniversalProxy.TuyaBeaconMesh.Crypto.key_bytes/1`, so
  each key/mask argument may be a 16-char string, a 32-char hex string, or the
  16 raw bytes. Which key encrypts and which masks depends on the destination:

  | destination | XXTEA key | XOR mask |
  |---|---|---|
  | unicast | localKey | beaconKey |
  | group (`FF gg`) | groupKey | beaconKey |
  | broadcast ping (`FF FF`) | beaconKey | beaconKey |
  | device → phone | beaconKey | beaconKey |

  The app nominally keys group frames with a groupKey, but bulbs never learn
  a distinct one: on hardware the groupKey *is* the beaconKey (see
  `docs/protocols/tuya_beacon_mesh.md` §4.9), which is what
  `UniversalProxy.TuyaBeaconMesh.Control` passes.

  Addresses (`src`, `dst`, node IDs) may be given as 2-byte binaries or as
  integers `0..0xFFFF`; parsed frames always return them as 2-byte binaries.

  Pure: no I/O.
  """
  import Bitwise

  alias UniversalProxy.TuyaBeaconMesh.Crypto
  alias UniversalProxy.TuyaBeaconMesh.Dp

  @type addr :: <<_::16>> | 0..0xFFFF
  @type key :: String.t() | <<_::128>>
  @type expect :: :none | :dp_report | :reset_ack | :ping_reply | :group_list
  @type request :: {binary(), non_neg_integer(), non_neg_integer(), expect()}

  @type unpaired :: %{
          srand: String.t(),
          mac: String.t(),
          pid: String.t(),
          sv: String.t(),
          flag: String.t(),
          srand_enc: String.t()
        }

  @type device_frame :: %{
          pair?: boolean(),
          type: 0..15,
          src: <<_::16>>,
          dst: <<_::16>>,
          sn: 0..0xFFFF,
          sub_cmd: byte(),
          payload: <<_::128>>
        }

  # ---------------------------------------------------------------- unpaired

  @doc """
  Parses a 26-byte unpaired advert (§4.5): pair flag set, type 1, flag byte 0,
  and the frame CRC over `[hdr & 0xFC]` ‖ bytes 1..24 (header `0x88`–`0x8B`).

  Returns the fields in the shapes the cloud calls expect: `srand`, `mac` and
  `srand_enc` as lowercase hex strings, `sv` as e.g. `"1.2"`, and `flag` as a
  string. Returns `:error` for anything that is not a valid unpaired advert.
  """
  @spec parse_unpaired(binary()) :: {:ok, unpaired()} | :error
  def parse_unpaired(<<hdr, _::binary-24, crc>> = frame) when byte_size(frame) == 26 do
    <<_, srand::binary-4, mac::binary-6, pid::binary-8, sv, flag, srand_enc::binary-4, _>> =
      frame

    cond do
      (hdr &&& 0x80) == 0 ->
        :error

      (hdr >>> 3 &&& 0xF) != 1 ->
        :error

      flag != 0 ->
        :error

      Crypto.crc8(<<hdr &&& 0xFC>> <> binary_part(frame, 1, 24)) != crc ->
        :error

      true ->
        {:ok,
         %{
           srand: hex(srand),
           mac: hex(mac),
           pid: String.replace(pid, " ", ""),
           sv: "#{div(sv, 16)}.#{rem(sv, 16)}",
           flag: Integer.to_string(flag),
           srand_enc: hex(srand_enc)
         }}
    end
  end

  def parse_unpaired(_), do: :error

  # ------------------------------------------------------------------- frames

  @doc """
  Builds a 26-byte P2 frame (§4.2) from frame `type`, `sub_cmd`, `src`, `dst`,
  sequence number `sn`, `payload` (at most 16 bytes, zero-padded), the XXTEA
  `key` and the XOR `mask`. The payload CRC is computed over the padded
  payload and the frame CRC over the frame before masking.
  """
  @spec build(0..31, byte(), addr(), addr(), 0..0xFFFF, binary(), key(), key()) :: binary()
  def build(type, sub_cmd, src, dst, sn, payload, key, mask)
      when type in 0..31 and sub_cmd in 0..255 and sn in 0..0xFFFF and is_binary(payload) and
             byte_size(payload) <= 16 do
    src = addr!(src)
    dst = addr!(dst)
    key = Crypto.key_bytes(key)
    mask = Crypto.key_bytes(mask)

    padded = payload <> :binary.copy(<<0>>, 16 - byte_size(payload))
    cipher = Crypto.xxtea_encrypt(padded, key)
    hdr = (type <<< 3) + 3 &&& 0xFF

    inner =
      src <> dst <> <<sn::16-big, sub_cmd, Crypto.crc8(padded)>> <> cipher

    crc = Crypto.crc8(<<hdr &&& 0xFC>> <> inner)
    masked = :crypto.exor(cipher, mask)

    <<hdr>> <> src <> dst <> <<sn::16-big, sub_cmd, Crypto.crc8(padded)>> <> masked <> <<crc>>
  end

  def build(_, _, _, _, _, payload, _, _) when is_binary(payload) do
    raise ArgumentError, "P2 payload must be at most 16 bytes, got #{byte_size(payload)}"
  end

  @doc """
  Builds the P2Pair frame (§4.5): header `0x93`, not masked and with no
  sequence number. It carries MAC bytes 2..5, the pairing `round`, the cloud
  assigned `node_id`, `crc8(beaconKey)`, and the beaconKey XXTEA-encrypted
  with the localKey. The trailing CRC is over `[0x90]` ‖ bytes 1..24.
  """
  @spec pair_frame(key(), binary(), addr(), key(), byte()) :: binary()
  def pair_frame(local_key, mac, node_id, beacon_key, round)
      when round in 0..255 do
    mac = mac!(mac)
    beacon_key = Crypto.key_bytes(beacon_key)
    <<_::binary-2, mac_tail::binary-4>> = mac

    inner =
      mac_tail <>
        <<round>> <>
        addr!(node_id) <>
        <<Crypto.crc8(beacon_key)>> <>
        Crypto.xxtea_encrypt(beacon_key, Crypto.key_bytes(local_key))

    <<0x93>> <> inner <> <<Crypto.crc8(<<0x90>> <> inner)>>
  end

  @doc """
  Parses a device → phone frame (§4.2, §4.6): the destination must be `8000`
  or `8001`, then the frame is unmasked with the beaconKey, both CRCs are
  checked, and the payload is decrypted with the beaconKey.

  The payload is returned as the full decrypted 16 bytes (zero-padded); decode
  DP reports from it with `UniversalProxy.TuyaBeaconMesh.Dp.decode/1`. Returns `:error` for a
  wrong size or destination, a bad key, or either CRC failing.
  """
  @spec parse_device(binary(), key()) :: {:ok, device_frame()} | :error
  def parse_device(frame, beacon_key) when byte_size(frame) == 26 do
    <<hdr, src::binary-2, dst::binary-2, sn::16-big, sub_cmd, payload_crc, masked::binary-16,
      frame_crc>> = frame

    with true <- dst in [<<0x80, 0x00>>, <<0x80, 0x01>>],
         {:ok, key} <- fetch_key(beacon_key) do
      cipher = :crypto.exor(masked, key)
      inner = src <> dst <> <<sn::16-big, sub_cmd, payload_crc>> <> cipher

      if Crypto.crc8(<<hdr &&& 0xFC>> <> inner) != frame_crc do
        :error
      else
        payload = Crypto.xxtea_decrypt(cipher, key)

        if Crypto.crc8(payload) == payload_crc do
          {:ok,
           %{
             pair?: (hdr &&& 0x80) != 0,
             type: hdr >>> 3 &&& 0xF,
             src: src,
             dst: dst,
             sn: sn,
             sub_cmd: sub_cmd,
             payload: payload
           }}
        else
          :error
        end
      end
    else
      _ -> :error
    end
  end

  def parse_device(_, _), do: :error

  @doc """
  Clears the header's hop bits (1–0, the TTL that relaying bulbs decrement),
  which both CRCs exclude, so that copies of one frame relayed by different
  bulbs (or one bulb several times) compare equal and dedupe. The CRC byte
  stays valid.
  """
  @spec normalize(binary()) :: binary()
  def normalize(<<hdr, rest::binary>>), do: <<hdr &&& 0xFC, rest::binary>>
  def normalize(<<>>), do: <<>>

  # ------------------------------------------------------- request builders
  #
  # Each builder returns `{frame, send_ms, window_ms, expect}` with the §4.7
  # timings. `expect` says what reply, if any, completes the request (§4.6):
  # `:dp_report` (a DP report), `:reset_ack` (type 1, subCmd 2, payload `02`),
  # `:ping_reply` (type 1, subCmd 2, payload `01`), `:group_list` (type 1,
  # subCmd 2, payload `A3 …`), or `:none`. Replies are matched by source
  # address and reply kind only; no sequence number is echoed.
  #
  # Callers pass the key/mask pair for the destination (see the table in the
  # moduledoc): unicast is `(localKey, beaconKey)`, a group destination is
  # `(groupKey, beaconKey)` (groupKey = beaconKey in practice), and a
  # broadcast ping is `(beaconKey, beaconKey)`.

  @doc """
  DP set with no acknowledgement (type 1, subCmd `0x05`, §4.7: send 3000 ms,
  window 5000 ms, no ack expected). `dps` is a list of
  `UniversalProxy.TuyaBeaconMesh.Dp` tuples or an already-encoded payload binary.
  For a group destination pass `dst` as `<<0xFF, gg>>` with the group key.
  """
  @spec dp_set(addr(), addr(), 0..0xFFFF, [Dp.dp()] | binary(), key(), key()) :: request()
  def dp_set(src, dst, sn, dps, key, mask) do
    {build(1, 0x05, src, dst, sn, dp_payload!(dps), key, mask), 3000, 5000, :none}
  end

  @doc """
  DP set with acknowledgement wanted (type 1, subCmd `0x06`, §4.7: send
  1000 ms, window 1000 ms). The bulb answers with a DP report (§4.6).
  Unicast only: pass the localKey/beaconKey pair.
  """
  @spec dp_set_ack(addr(), addr(), 0..0xFFFF, [Dp.dp()] | binary(), key(), key()) :: request()
  def dp_set_ack(src, dst, sn, dps, key, mask) do
    {build(1, 0x06, src, dst, sn, dp_payload!(dps), key, mask), 1000, 1000, :dp_report}
  end

  @doc """
  Reset one bulb (type 1, subCmd `0x01`, payload `02`, §4.7: send 2000 ms,
  window 2000 ms). The bulb acknowledges with payload `02` (§4.6), restores
  its default beaconKey, and advertises unpaired with a new srand.
  """
  @spec reset(addr(), addr(), 0..0xFFFF, key(), key()) :: request()
  def reset(src, dst, sn, key, mask) do
    {build(1, 0x01, src, dst, sn, <<0x02>>, key, mask), 2000, 2000, :reset_ack}
  end

  @doc """
  Ping (type 2, subCmd `0x01`, payload `01`, §4.7: send 2000 ms, window
  2000 ms, or 5000 ms when the destination is the broadcast address
  `FF FF`). For broadcast pass the beaconKey as both key and mask.
  """
  @spec ping(addr(), addr(), 0..0xFFFF, key(), key()) :: request()
  def ping(src, dst, sn, key, mask) do
    window = if addr!(dst) == <<0xFF, 0xFF>>, do: 5000, else: 2000
    {build(2, 0x01, src, dst, sn, <<0x01>>, key, mask), 2000, window, :ping_reply}
  end

  @doc """
  Add the addressed bulb to group `gg` (type 1, subCmd `0x01`, payload
  `A1 gg`, §4.7: send 5000 ms, window 5000 ms). The bulb answers with its
  group list (§4.6). Unicast: pass the localKey/beaconKey pair.
  A bulb holds at most 8 group slots.
  """
  @spec group_add(addr(), addr(), 0..0xFFFF, byte() | <<_::8>>, key(), key()) :: request()
  def group_add(src, dst, sn, gg, key, mask) do
    {build(1, 0x01, src, dst, sn, <<0xA1>> <> group_id!(gg), key, mask), 5000, 5000, :group_list}
  end

  @doc """
  Remove the addressed bulb from the given groups (type 1, subCmd `0x01`,
  payload `A2 g1 [g2 …]`, §4.7: send 5000 ms, window 5000 ms). `groups` is a
  group ID, a list of group IDs, or a binary of group ID bytes. The bulb
  answers with its group list (§4.6).
  """
  @spec group_remove(addr(), addr(), 0..0xFFFF, byte() | [byte()] | binary(), key(), key()) ::
          request()
  def group_remove(src, dst, sn, groups, key, mask) do
    {build(1, 0x01, src, dst, sn, <<0xA2>> <> group_ids!(groups), key, mask), 5000, 5000,
     :group_list}
  end

  @doc """
  Dismiss group `gg` (type 2, subCmd `0x01`, payload `A2 gg`, §4.7: send
  2000 ms, no listening window). The frame is addressed to the group itself
  (`FF gg`), so no destination argument is taken; pass the groupKey as key
  and the beaconKey as mask.
  """
  @spec group_dismiss(addr(), byte() | <<_::8>>, 0..0xFFFF, key(), key()) :: request()
  def group_dismiss(src, gg, sn, key, mask) do
    gg = group_id!(gg)
    {build(2, 0x01, src, <<0xFF>> <> gg, sn, <<0xA2>> <> gg, key, mask), 2000, 0, :none}
  end

  # ----------------------------------------------------------------- helpers

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp fetch_key(key) do
    {:ok, Crypto.key_bytes(key)}
  rescue
    ArgumentError -> :error
  end

  defp addr!(addr) when is_integer(addr) and addr in 0..0xFFFF, do: <<addr::16-big>>
  defp addr!(<<_::16>> = addr), do: addr

  defp addr!(addr),
    do:
      raise(
        ArgumentError,
        "address must be 2 bytes or an integer 0..65535, got: #{inspect(addr)}"
      )

  defp mac!(mac) when byte_size(mac) == 6, do: mac
  defp mac!(mac) when byte_size(mac) == 12, do: Base.decode16!(mac, case: :mixed)

  defp mac!(mac) when byte_size(mac) == 17,
    do: mac |> String.replace(":", "") |> Base.decode16!(case: :mixed)

  defp mac!(mac),
    do:
      raise(
        ArgumentError,
        "MAC must be 6 bytes or a hex string, got: #{inspect(mac)}"
      )

  defp dp_payload!(payload) when is_binary(payload), do: payload

  defp dp_payload!(dps) when is_list(dps) do
    case Dp.encode(dps) do
      {:ok, payload} -> payload
      {:error, reason} -> raise ArgumentError, "cannot encode DPs: #{inspect(reason)}"
    end
  end

  defp group_id!(gg) when is_integer(gg) and gg in 0..255, do: <<gg>>
  defp group_id!(<<_::8>> = gg), do: gg

  defp group_id!(gg),
    do: raise(ArgumentError, "group ID must be a byte, got: #{inspect(gg)}")

  defp group_ids!(groups) when is_integer(groups), do: group_id!(groups)
  defp group_ids!(<<_::binary>> = groups) when byte_size(groups) > 0, do: groups

  defp group_ids!(groups) when is_list(groups) and groups != [] do
    if Enum.all?(groups, &(&1 in 0..255)) do
      :binary.list_to_bin(groups)
    else
      raise ArgumentError, "group IDs must be bytes, got: #{inspect(groups)}"
    end
  end

  defp group_ids!(groups),
    do: raise(ArgumentError, "expected at least one group ID, got: #{inspect(groups)}")
end
