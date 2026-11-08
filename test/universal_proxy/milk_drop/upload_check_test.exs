defmodule UniversalProxy.MilkDrop.UploadCheckTest do
  use ExUnit.Case, async: true

  import UniversalProxy.MilkDropUploadFixtures

  alias UniversalProxy.MilkDrop.UploadCheck

  describe "normalise_name/1" do
    test "normalises like the pack: spaces squashed, stem trimmed, extension lowercased" do
      assert UploadCheck.normalise_name("My  Preset .MILK") == {:ok, "My Preset.milk"}
      assert UploadCheck.normalise_name(" a  b .milk") == {:ok, "a b.milk"}
      assert UploadCheck.normalise_name("Stars.JPEG") == {:ok, "Stars.jpeg"}
      assert UploadCheck.normalise_name("x.Png") == {:ok, "x.png"}
    end

    test "keeps Unicode letters, NFC-normalised" do
      assert UploadCheck.normalise_name("cafe\u0301.milk") == {:ok, "café.milk"}
      assert UploadCheck.normalise_name("Ünïcödé 日本.milk") == {:ok, "Ünïcödé 日本.milk"}
    end

    test "accepts the allowed punctuation" do
      name = "Geiss & Rovastar - (v2) [mix], it's #1 +more! @$%=~;_.milk"
      assert UploadCheck.normalise_name(name) == {:ok, name}
    end

    test "rejects disallowed characters, control and format characters" do
      for name <- [
            "a/b.milk",
            "a\\b.milk",
            "a:b.milk",
            "a*b.milk",
            "a?b.milk",
            "a\"b.milk",
            "a<b>.milk",
            "a|b.milk",
            "a\tb.milk",
            "a\nb.milk",
            "a\0b.milk",
            "evil\u202Eklim.png",
            "zero\u200Bwidth.milk",
            "\uFEFFbom.milk",
            "a\u2066b.milk"
          ] do
        assert UploadCheck.normalise_name(name) == {:error, :invalid_name}, inspect(name)
      end
    end

    test "rejects dots, empty stems, bad extensions, invalid UTF-8 and long names" do
      for name <- [
            ".milk",
            " .milk",
            ".hidden.milk",
            "trailing..milk",
            "a..b.milk",
            "x.txt",
            "x",
            "x.milk.zip",
            <<"caf", 0xE9, ".milk">>,
            String.duplicate("a", 196) <> ".milk"
          ] do
        assert UploadCheck.normalise_name(name) == {:error, :invalid_name}, inspect(name)
      end

      assert {:ok, _} = UploadCheck.normalise_name(String.duplicate("a", 195) <> ".milk")
      # 200 bytes, counted in bytes rather than characters.
      assert {:error, :invalid_name} =
               UploadCheck.normalise_name(String.duplicate("é", 98) <> ".milk")

      assert {:ok, _} = UploadCheck.normalise_name(String.duplicate("é", 97) <> ".milk")
    end

    test "accepted names make valid renderer ids under user/" do
      {:ok, name} = UploadCheck.normalise_name("A preset.MILK")
      assert UploadCheck.preset_id(name) == "user/A preset.milk"
    end
  end

  describe "fold/1, texture_key/1, kind/1" do
    test "fold ignores case and NFC/NFD" do
      assert UploadCheck.fold("Café.milk") == UploadCheck.fold("CAFE\u0301.MILK")
      refute UploadCheck.fold("a.milk") == UploadCheck.fold("b.milk")
    end

    test "texture_key compares by stem" do
      assert UploadCheck.texture_key("Stars.png") == UploadCheck.texture_key("stars.JPG")
    end

    test "kind by extension" do
      assert UploadCheck.kind("a.MILK") == :preset
      assert UploadCheck.kind("a.jpeg") == :texture
      assert UploadCheck.kind("a.gif") == :other
      assert UploadCheck.kind("README") == :other
    end

    test "reserved texture names, behind any XY_ prefix as projectM strips it" do
      for name <-
            ~w(main.png Noise_LQ.jpg fc_main.png pw_noisevol_hq.jpg blur2.png cf_main.png
               wf_noise_lq.jpg idlem.png idleheadphones.png zz_idlem.png 9__blur1.png) do
        assert UploadCheck.texture_reserved?(name), name
      end

      for name <- ~w(mainframe.png fcmain.png f_main.png abc_main.png fc_.png idle.png) do
        refute UploadCheck.texture_reserved?(name), name
      end
    end
  end

  describe "printable/1" do
    test "replaces invalid UTF-8, control and format characters; truncates" do
      assert UploadCheck.printable(<<"a", 0xFF, "b\n\u202Ec">>) == "a?b??c"
      assert byte_size(UploadCheck.printable(String.duplicate("é", 300))) == 200
    end
  end

  describe "check_preset/1" do
    test "accepts UTF-8 and Latin-1 presets" do
      assert UploadCheck.check_preset(milk()) == :ok
      assert UploadCheck.check_preset(milk("// café ☕\n")) == :ok
      assert UploadCheck.check_preset(milk(<<"// caf", 0xE9, "\n">>)) == :ok
      assert UploadCheck.check_preset("MILKDROP_PRESET_VERSION=201\nzoom=1") == :ok
    end

    test "rejects oversize files" do
      line = String.duplicate("a", 1000) <> "\n"

      assert UploadCheck.check_preset("a=1\n" <> String.duplicate(line, 263)) ==
               {:error, :too_large}

      assert UploadCheck.check_preset("a=1\n" <> String.duplicate(line, 250)) == :ok
    end

    test "rejects NUL and C0 control bytes other than tab/LF/CR" do
      assert UploadCheck.check_preset(milk(<<0>>)) == {:error, :nul_byte}
      assert UploadCheck.check_preset(milk(<<0x1B, "[31m">>)) == {:error, :control_char}
      assert UploadCheck.check_preset(milk(<<0x0C>>)) == {:error, :control_char}
      assert UploadCheck.check_preset(milk("a\t=\t1\r\n")) == :ok
    end

    test "rejects too many or too long lines" do
      assert UploadCheck.check_preset("a=1" <> String.duplicate("\n", 20_000)) ==
               {:error, :too_many_lines}

      assert UploadCheck.check_preset("a=" <> String.duplicate("1", 64 * 1024)) ==
               {:error, :line_too_long}
    end

    test "requires a key=value line, as projectM's parser does" do
      assert UploadCheck.check_preset("") == {:error, :no_values}
      assert UploadCheck.check_preset("[preset00]\n\n=value\n") == {:error, :no_values}
      assert UploadCheck.check_preset("just some words\n") == {:error, :no_values}
      assert UploadCheck.check_preset("[preset00]\nkey=\n") == :ok
    end
  end

  describe "check_texture/2" do
    test "accepts PNG and JPEG headers within the limits" do
      assert UploadCheck.check_texture("a.png", png(256, 128)) ==
               {:ok, %{format: :png, width: 256, height: 128}}

      assert UploadCheck.check_texture("a.jpg", jpeg(2048, 2048)) ==
               {:ok, %{format: :jpeg, width: 2048, height: 2048}}

      assert {:ok, %{format: :jpeg}} = UploadCheck.check_texture("a.JPEG", jpeg(1, 1, sof: 0xC1))
    end

    test "rejects oversize dimensions" do
      assert UploadCheck.check_texture("a.png", png(2049, 16)) ==
               {:error, {:dimensions, 2049, 16}}

      assert UploadCheck.check_texture("a.png", png(16, 16_384)) ==
               {:error, {:dimensions, 16, 16_384}}

      assert UploadCheck.check_texture("a.png", png(0, 16)) == {:error, {:dimensions, 0, 16}}
      assert UploadCheck.check_texture("a.jpg", jpeg(4096, 1)) == {:error, {:dimensions, 4096, 1}}
      assert UploadCheck.check_texture("a.jpg", jpeg(16, 0)) == {:error, {:dimensions, 16, 0}}
    end

    test "rejects magic bytes that don't match the extension" do
      assert UploadCheck.check_texture("a.png", jpeg(16, 16)) == {:error, :bad_magic}
      assert UploadCheck.check_texture("a.jpg", png(16, 16)) == {:error, :bad_magic}
      assert UploadCheck.check_texture("a.png", "GIF89a....") == {:error, :bad_magic}
      assert UploadCheck.check_texture("a.png", "") == {:error, :bad_magic}
      assert UploadCheck.check_texture("a.dds", png(16, 16)) == {:error, :bad_magic}
    end

    test "rejects malformed headers" do
      <<head::binary-16, _::binary>> = png(16, 16)
      assert UploadCheck.check_texture("a.png", head) == {:error, :bad_header}
      assert UploadCheck.check_texture("a.png", png(16, 16, depth: 3)) == {:error, :bad_header}
      assert UploadCheck.check_texture("a.png", png(16, 16, color: 5)) == {:error, :bad_header}

      assert UploadCheck.check_texture("a.jpg", <<0xFF, 0xD8, 0xFF>>) == {:error, :bad_header}
      assert UploadCheck.check_texture("a.jpg", jpeg(16, 16, eoi: "")) == {:error, :bad_header}

      # Scan data before any frame header.
      sos_first = <<0xFF, 0xD8, 0xFF, 0xDA, 4::16, 0, 0, 0xFF, 0xD9>>
      assert UploadCheck.check_texture("a.jpg", sos_first) == {:error, :bad_header}

      # A segment length running past the end.
      assert UploadCheck.check_texture("a.jpg", <<0xFF, 0xD8, 0xFF, 0xE0, 0xFF, 0xFF, 0>>) ==
               {:error, :bad_header}
    end

    test "enforces the legal PNG bit depth for each colour type" do
      legal = %{
        0 => [1, 2, 4, 8, 16],
        2 => [8, 16],
        3 => [1, 2, 4, 8],
        4 => [8, 16],
        6 => [8, 16]
      }

      for color <- [0, 2, 3, 4, 6], depth <- [1, 2, 4, 8, 16] do
        result = UploadCheck.check_texture("a.png", png(8, 8, color: color, depth: depth))

        if depth in legal[color],
          do: assert({:ok, %{format: :png}} = result),
          else: assert(result == {:error, :bad_header}, "color #{color} depth #{depth}")
      end
    end

    test "requires the whole IHDR chunk with a matching CRC" do
      full = png(16, 16)
      # Signature, length, type and data but no CRC: 29 bytes.
      assert UploadCheck.check_texture("a.png", binary_part(full, 0, 29)) == {:error, :bad_header}
      assert UploadCheck.check_texture("a.png", binary_part(full, 0, 33)) == {:error, :bad_header}
      assert {:ok, _} = UploadCheck.check_texture("a.png", full)

      <<head::binary-29, crc::32, rest::binary>> = full
      bad_crc = <<head::binary, Bitwise.bxor(crc, 1)::32, rest::binary>>
      assert UploadCheck.check_texture("a.png", bad_crc) == {:error, :bad_header}
    end

    test "walks PNG chunks: CRCs, IEND, nothing past the end" do
      assert {:ok, _} =
               UploadCheck.check_texture(
                 "a.png",
                 png(8, 8, tail: chunk("tEXt", "a\0b") <> chunk("IEND", ""))
               )

      # A bad CRC on a later chunk.
      bad_crc = <<1::32, "tEXt", "x", 0::32>>

      assert UploadCheck.check_texture("a.png", png(8, 8, tail: bad_crc <> chunk("IEND", ""))) ==
               {:error, :bad_header}

      # No IEND, a chunk running past the end, a second IHDR.
      assert UploadCheck.check_texture("a.png", png(8, 8, tail: "")) == {:error, :bad_header}

      assert UploadCheck.check_texture("a.png", png(8, 8, tail: <<100::32, "tEXt", "short">>)) ==
               {:error, :bad_header}

      assert UploadCheck.check_texture(
               "a.png",
               png(8, 8, tail: chunk("IHDR", :binary.copy(<<0>>, 13)) <> chunk("IEND", ""))
             ) ==
               {:error, :bad_header}
    end

    test "rejects an IDAT decompression bomb behind tiny dimensions" do
      bomb = :zlib.compress(:binary.copy(<<0>>, 16 * 1024 * 1024))
      data = png(1, 1, idat: bomb)
      assert byte_size(data) < 100_000

      {us, result} = :timer.tc(fn -> UploadCheck.check_texture("a.png", data) end)
      assert result == {:error, :bad_image}
      # Stops at the 5-byte cap rather than inflating 16 MiB.
      assert us < 1_000_000
    end

    test "requires IDAT to inflate to exactly the raw size" do
      raw = fn size -> :zlib.compress(:binary.copy(<<0>>, size)) end
      # 8×8 RGBA, 8-bit: 8 × (1 + 32) = 264 bytes.
      assert {:ok, _} = UploadCheck.check_texture("a.png", png(8, 8, idat: raw.(264)))

      assert UploadCheck.check_texture("a.png", png(8, 8, idat: raw.(263))) ==
               {:error, :bad_image}

      assert UploadCheck.check_texture("a.png", png(8, 8, idat: raw.(265))) ==
               {:error, :bad_image}

      assert UploadCheck.check_texture("a.png", png(8, 8, idat: "not zlib")) ==
               {:error, :bad_image}

      # 1-bit greyscale packs rows: 8 × (1 + 1).
      assert {:ok, _} =
               UploadCheck.check_texture("a.png", png(8, 8, color: 0, depth: 1, idat: raw.(16)))

      # IEND with no IDAT at all.
      no_idat =
        <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A>> <>
          binary_part(png(8, 8), 8, 25) <> chunk("IEND", "")

      assert UploadCheck.check_texture("a.png", no_idat) == {:error, :bad_image}
    end

    test "requires 8-bit JPEG sample precision" do
      good = jpeg(16, 16)
      {pos, _} = :binary.match(good, <<0xFF, 0xC0>>)
      # The precision byte follows the marker and its 2-byte length.
      assert binary_part(good, pos + 4, 1) == <<8>>

      for precision <- [12, 0] do
        bad =
          binary_part(good, 0, pos + 4) <>
            <<precision>> <> binary_part(good, pos + 5, byte_size(good) - pos - 5)

        assert UploadCheck.check_texture("a.jpg", bad) == {:error, :bad_header},
               "precision #{precision}"
      end
    end

    test "JPEG components: 1, 3 or 4 of them, with distinct ids" do
      sof = fn specs ->
        body = <<8, 1::16, 1::16, div(byte_size(specs), 3), specs::binary>>
        <<0xFF, 0xD8, 0xFF, 0xC0, byte_size(body) + 2::16, body::binary, 0xFF, 0xD9>>
      end

      two = <<1, 0x11, 0, 2, 0x11, 0>>
      assert UploadCheck.check_texture("a.jpg", sof.(two)) == {:error, :bad_header}

      same_ids = <<1, 0x11, 0, 1, 0x11, 0, 1, 0x11, 0>>
      assert UploadCheck.check_texture("a.jpg", sof.(same_ids)) == {:error, :bad_header}

      assert {:ok, _} =
               UploadCheck.check_texture("a.jpg", sof.(<<1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0>>))

      assert {:ok, _} =
               UploadCheck.check_texture(
                 "a.jpg",
                 sof.(<<1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0, 4, 0x11, 0>>)
               )
    end

    test "requires a complete JPEG frame header" do
      short_sof = <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x07, 0x08, 0x00, 0x01, 0x00, 0x01, 0xFF, 0xD9>>
      assert UploadCheck.check_texture("a.jpg", short_sof) == {:error, :bad_header}

      sof = fn nf, specs ->
        body = <<8, 1::16, 1::16, nf, specs::binary>>
        <<0xFF, 0xD8, 0xFF, 0xC0, byte_size(body) + 2::16, body::binary, 0xFF, 0xD9>>
      end

      assert {:ok, %{width: 1}} = UploadCheck.check_texture("a.jpg", sof.(1, <<1, 0x11, 0>>))
      assert UploadCheck.check_texture("a.jpg", sof.(0, "")) == {:error, :bad_header}
      # Sampling factors 1..4, quantisation table selector 0..3.
      assert UploadCheck.check_texture("a.jpg", sof.(1, <<1, 0x00, 0>>)) == {:error, :bad_header}
      assert UploadCheck.check_texture("a.jpg", sof.(1, <<1, 0x51, 0>>)) == {:error, :bad_header}
      assert UploadCheck.check_texture("a.jpg", sof.(1, <<1, 0x11, 4>>)) == {:error, :bad_header}
      assert {:ok, _} = UploadCheck.check_texture("a.jpg", sof.(1, <<1, 0x44, 3>>))

      assert UploadCheck.check_texture("a.jpg", sof.(5, :binary.copy(<<1, 0x11, 0>>, 5))) ==
               {:error, :bad_header}

      # Nf says three components, the segment holds two.
      assert UploadCheck.check_texture("a.jpg", sof.(3, :binary.copy(<<1, 0x11, 0>>, 2))) ==
               {:error, :bad_header}
    end

    test "a long run of fill bytes near the size cap is linear" do
      <<_soi::binary-2, rest::binary>> = jpeg(16, 16)
      fill = :binary.copy(<<0xFF>>, 4 * 1024 * 1024 - byte_size(rest) - 2)
      data = <<0xFF, 0xD8>> <> fill <> rest
      assert byte_size(data) == 4 * 1024 * 1024

      {us, result} = :timer.tc(fn -> UploadCheck.check_texture("a.jpg", data) end)
      assert {:ok, %{width: 16, height: 16}} = result
      assert us < 2_000_000
    end

    test "rejects interlaced PNGs and non-baseline JPEGs" do
      assert UploadCheck.check_texture("a.png", png(16, 16, interlace: 1)) ==
               {:error, :interlaced}

      for sof <- [0xC2, 0xC3, 0xC9, 0xCA, 0xCF] do
        assert UploadCheck.check_texture("a.jpg", jpeg(16, 16, sof: sof)) ==
                 {:error, :unsupported_jpeg}
      end
    end

    test "skips non-frame markers looking for the frame header" do
      # DHT (0xC4) shares the SOFn range but is not a frame header.
      dht = <<0xFF, 0xC4, 4::16, 0, 0>>
      <<soi::binary-2, rest::binary>> = jpeg(32, 8)

      assert {:ok, %{width: 32, height: 8}} =
               UploadCheck.check_texture("a.jpg", soi <> dht <> rest)
    end

    test "rejects files over 4 MiB" do
      big = png(16, 16) <> :binary.copy(<<0>>, 4 * 1024 * 1024)
      assert UploadCheck.check_texture("a.png", big) == {:error, :too_large}
    end
  end
end
