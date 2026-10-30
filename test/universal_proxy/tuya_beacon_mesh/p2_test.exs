defmodule UniversalProxy.TuyaBeaconMesh.P2Test do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaBeaconMesh.{Crypto, P2}

  @lk "abcdefghijklmnop"

  @vectors Path.join([__DIR__, "..", "..", "fixtures", "tuya_beacon_mesh", "vectors.json"])
           |> File.read!()
           |> Jason.decode!()
  @capture Path.join([
             __DIR__,
             "..",
             "..",
             "fixtures",
             "tuya_beacon_mesh",
             "p2_frames_2026-10-25.json"
           ])
           |> File.read!()
           |> Jason.decode!()

  @unpaired Enum.filter(@capture["frames"], &(&1["hdr"] in 0x88..0x8B))

  defp h(hex), do: Base.decode16!(hex, case: :mixed)

  describe "reference self-test vectors" do
    test "control frame: type 1, subCmd 5, 0001 -> 8002, sn 0x1234" do
      k1 = h("0123456789abcdeffedcba9876543210")

      assert P2.build(
               1,
               5,
               h("0001"),
               h("8002"),
               0x1234,
               h("01010101"),
               k1,
               h(String.duplicate("a5", 16))
             ) ==
               h("0b00018002123405c64f318331c42d21ffa70308a40769030074")
    end

    test "ping-shaped frame with an ASCII key and zero mask" do
      assert P2.build(2, 1, h("7fff"), h("0005"), 7, <<1>>, "abcdefghijklmnop", <<0::128>>) ==
               h("137fff000500070102ae24bdd3ca49b5952756a204bf1d01c0a8")
    end

    test "pair frame" do
      assert P2.pair_frame(
               "abcdefghijklmnop",
               h("dc234f001122"),
               h("0012"),
               h("00112233445566778899aabbccddeeff"),
               1
             ) ==
               h("934f0011220100124d4800ec463257ed3da4d4b4df741887cd1e")
    end
  end

  describe "vectors.json p2 entries" do
    test "pair frame, round 2, MAC as hex string" do
      v = @vectors["p2"]["pair_frame"]

      assert P2.pair_frame(v["local_key"], v["mac"], h(v["node_id"]), v["beacon_key"], v["round"]) ==
               h(v["frame"])
    end

    for name <- ["device_report", "pair_reply"] do
      test "parse_device: #{name}" do
        v = @vectors["p2"][unquote(name)]
        p = v["parsed"]

        assert {:ok, f} =
                 P2.parse_device(h(v["frame"]), @vectors["p2"]["device_report"]["beacon_key"])

        assert f.pair? == p["pair"]
        assert f.type == p["cmd"]
        assert f.src == h(p["src"])
        assert f.dst == h(p["dst"])
        assert f.sn == p["sn"]
        assert f.sub_cmd == p["sub_cmd"]
        assert f.payload == h(p["payload"])
      end
    end

    test "parse_device rejects a wrong key, a non-phone destination and a bad CRC" do
      v = @vectors["p2"]["device_report"]
      frame = h(v["frame"])
      assert P2.parse_device(frame, "ffeeddccbbaa99887766554433221100") == :error
      assert P2.parse_device(binary_part(frame, 0, 25) <> <<0>>, v["beacon_key"]) == :error
      <<a::binary-3, _::16, rest::binary>> = frame
      assert P2.parse_device(a <> <<0x12, 0x34>> <> rest, v["beacon_key"]) == :error
    end

    test "parse_device checks the payload CRC under a valid frame CRC" do
      bk = h("00112233445566778899aabbccddeeff")
      frame = P2.build(1, 7, 0x0042, 0x8001, 9, h("0111"), bk, bk)
      assert {:ok, _} = P2.parse_device(frame, bk)

      # Flip the payload CRC byte and re-seal the frame CRC (computed over
      # the unmasked frame) so only the payload check can catch it.
      <<hdr, head::binary-7, payload_crc, masked::binary-16, _crc>> = frame
      cipher = :crypto.exor(masked, bk)
      bad_crc = Bitwise.bxor(payload_crc, 0x01)
      sealed = Crypto.crc8(<<Bitwise.band(hdr, 0xFC)>> <> head <> <<bad_crc>> <> cipher)
      forged = <<hdr>> <> head <> <<bad_crc>> <> masked <> <<sealed>>

      assert P2.parse_device(forged, bk) == :error
    end

    test "parse_device and parse_unpaired reject malformed input" do
      v = @vectors["p2"]["device_report"]
      frame = h(v["frame"])
      key = v["beacon_key"]

      for bad <- [<<>>, binary_part(frame, 0, 25), frame <> <<0>>, nil, 42] do
        assert P2.parse_device(bad, key) == :error
        assert P2.parse_unpaired(bad) == :error
      end

      for bad_key <- [nil, "short", String.duplicate("z", 32), 7] do
        assert P2.parse_device(frame, bad_key) == :error
      end

      u = hd(@unpaired) |> Map.fetch!("frame") |> h()
      <<hdr, mid::binary-23, flag_etc::binary-1, crc>> = u
      # Pair flag cleared, type != 1, flag byte set: each re-sealed so only
      # the field check rejects it.
      reseal = fn <<hdr, rest::binary-24, _crc>> ->
        <<hdr, rest::binary, Crypto.crc8(<<Bitwise.band(hdr, 0xFC)>> <> rest)>>
      end

      assert P2.parse_unpaired(
               reseal.(<<Bitwise.band(hdr, 0x7F), mid::binary, flag_etc::binary, crc>>)
             ) == :error

      assert P2.parse_unpaired(reseal.(<<0x90, mid::binary, flag_etc::binary, crc>>)) == :error

      <<pre::binary-20, _flag, post::binary-5>> = u
      assert P2.parse_unpaired(reseal.(<<pre::binary, 1, post::binary>>)) == :error
      assert {:ok, _} = P2.parse_unpaired(reseal.(u))
    end

    test "build takes 4-bit frame types only" do
      assert <<0x7B, _::binary>> = P2.build(15, 1, 1, 2, 3, <<>>, @lk, @lk)

      assert_raise FunctionClauseError, fn -> P2.build(16, 1, 1, 2, 3, <<>>, @lk, @lk) end
    end

    test "build -> parse_device round trip for a frame to 8000" do
      bk = h("00112233445566778899aabbccddeeff")
      frame = P2.build(1, 9, 0x0042, 0x8000, 65_535, h("0111"), bk, bk)

      assert {:ok, %{src: <<0, 0x42>>, sn: 65_535, sub_cmd: 9, payload: <<1, 0x11, _::binary>>}} =
               P2.parse_device(frame, bk)
    end
  end

  describe "real capture (2026-10-25)" do
    test "ten unpaired adverts parse, pid vd8o60wy, MAC = advertiser" do
      assert length(@unpaired) == 10

      for f <- @unpaired do
        assert {:ok, u} = P2.parse_unpaired(h(f["frame"]))
        assert u.pid == "vd8o60wy"
        assert u.sv == "1.2"
        assert u.flag == "0"
        assert String.upcase(u.mac) == f["addr"]
        assert byte_size(u.srand) == 8 and byte_size(u.srand_enc) == 8
      end
    end

    test "parse_unpaired rejects a corrupted CRC and a relayed control frame" do
      f = hd(@unpaired)["frame"] |> h()
      assert P2.parse_unpaired(binary_part(f, 0, 25) <> <<bxor_byte(:binary.last(f))>>) == :error
      relayed = Enum.find(@capture["frames"], &(&1["hdr"] in 0x08..0x0A))
      assert P2.parse_unpaired(h(relayed["frame"])) == :error
    end

    test "relayed copies with different hop bits normalise to one frame" do
      groups =
        @capture["frames"]
        |> Enum.filter(&(&1["hdr"] in 0x08..0x0B))
        |> Enum.group_by(&binary_part(h(&1["frame"]), 1, 25))
        |> Enum.filter(fn {_, fs} ->
          fs |> Enum.map(& &1["hdr"]) |> Enum.uniq() |> length() > 1
        end)

      assert groups != []

      for {_, fs} <- groups do
        assert fs |> Enum.map(&P2.normalize(h(&1["frame"]))) |> Enum.uniq() |> length() == 1
      end
    end
  end

  describe "request builders" do
    @bk "00112233445566778899aabbccddeeff"

    test "timings and expectations per §4.7" do
      assert {f, 3000, 5000, :none} = P2.dp_set(0x1001, 0x0012, 1, [{1, :bool, true}], @lk, @bk)
      assert <<0x0B, 0x10, 0x01, 0x00, 0x12, 0, 1, 0x05, _::binary>> = f

      assert {<<0x0B, _::binary-6, 0x06, _::binary>>, 1000, 1000, :dp_report} =
               P2.dp_set_ack(0x1001, 0x0012, 2, [{1, :bool, true}], @lk, @bk)

      assert {<<0x0B, _::binary-6, 0x01, _::binary>>, 2000, 2000, :reset_ack} =
               P2.reset(0x1001, 0x0012, 3, @lk, @bk)

      assert {<<0x13, _::binary>>, 2000, 2000, :ping_reply} = P2.ping(0x1001, 0x0012, 4, @lk, @bk)
      assert {_, 2000, 5000, :ping_reply} = P2.ping(0x1001, 0xFFFF, 5, @bk, @bk)
      assert {_, 5000, 5000, :group_list} = P2.group_add(0x1001, 0x0012, 6, 7, @lk, @bk)
      assert {_, 5000, 5000, :group_list} = P2.group_remove(0x1001, 0x0012, 7, [7, 9], @lk, @bk)

      assert {<<0x13, 0x10, 0x01, 0xFF, 0x07, _::binary>>, 2000, 0, :none} =
               P2.group_dismiss(0x1001, 7, 8, "ffeeddccbbaa99887766554433221100", @bk)
    end
  end

  defp bxor_byte(b), do: Bitwise.bxor(b, 0xFF)
end
