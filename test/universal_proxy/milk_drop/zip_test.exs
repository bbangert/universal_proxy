defmodule UniversalProxy.MilkDrop.ZipTest do
  use ExUnit.Case, async: true

  import Bitwise
  import UniversalProxy.MilkDropUploadFixtures

  alias UniversalProxy.MilkDrop.UploadCheck
  alias UniversalProxy.MilkDrop.Zip
  alias UniversalProxy.MilkDrop.Zip.Entry

  defp open(bin, opts \\ []), do: Zip.open({:binary, bin}, opts)

  defp read_all(bin) do
    {:ok, zip} = open(bin)

    for %Entry{dir?: false} = entry <- Zip.entries(zip),
        do: {entry.name, Zip.read(zip, entry)}
  end

  describe "happy paths" do
    test "stored and deflated entries, nested folders and directory entries" do
      text = String.duplicate("per_frame_1=zoom=zoom+0.01;\n", 200)

      bin =
        zip([
          [name: "pack/"],
          [name: "pack/sub/"],
          [name: "pack/a.milk", data: "a=1"],
          [name: "pack/sub/b.milk", data: text, method: :deflate]
        ])

      {:ok, zip} = open(bin)

      assert [
               %Entry{name: "pack/", dir?: true},
               %Entry{name: "pack/sub/", dir?: true},
               %Entry{name: "pack/a.milk", dir?: false, method: :stored, size: 3},
               %Entry{name: "pack/sub/b.milk", method: :deflate} = b
             ] = Zip.entries(zip)

      assert b.size == byte_size(text)
      assert b.compressed_size < b.size
      assert read_all(bin) == [{"pack/a.milk", {:ok, "a=1"}}, {"pack/sub/b.milk", {:ok, text}}]
      assert :ok = Zip.close(zip)
    end

    test "reads an archive made by OTP's :zip" do
      files = [{~c"x/a.milk", "a=1"}, {~c"b.png", :crypto.strong_rand_bytes(3_000)}]
      {:ok, {_, bin}} = :zip.create(~c"t.zip", files, [:memory])

      [_, {_, png}] = files
      assert read_all(bin) == [{"x/a.milk", {:ok, "a=1"}}, {"b.png", {:ok, png}}]
    end

    @tag :tmp_dir
    test "reads from a file path with pread", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "u.zip")
      File.write!(path, zip([[name: "a.milk", data: "a=1", method: :deflate]], comment: "hi"))

      {:ok, zip} = Zip.open(path)
      assert [entry] = Zip.entries(zip)
      assert Zip.read(zip, entry) == {:ok, "a=1"}
      assert :ok = Zip.close(zip)
    end

    test "accepts data descriptors: zero local CRC/sizes, CD authoritative" do
      data = String.duplicate("q=1\n", 100)
      descriptor = <<"PK", 7, 8, :erlang.crc32(data)::little-32, 0::32, 0::32>>

      bin =
        zip([
          [
            name: "a.milk",
            data: data,
            method: :deflate,
            flags: 0x0808,
            local_crc: 0,
            local_csize: 0,
            local_usize: 0,
            trailer: descriptor
          ],
          [name: "b.milk", data: "b=2"]
        ])

      assert read_all(bin) == [{"a.milk", {:ok, data}}, {"b.milk", {:ok, "b=2"}}]
    end

    test "accepts DOS-made entries (no Unix mode) and an archive comment" do
      bin = zip([[name: "a.milk", data: "a=1", ext_attr: 0x20]], comment: "made on DOS")
      assert read_all(bin) == [{"a.milk", {:ok, "a=1"}}]
    end

    test "accepts UTF-8 names without flag bit 11" do
      bin = zip([[name: "café.milk", data: "a=1", flags: 0]])
      assert read_all(bin) == [{"café.milk", {:ok, "a=1"}}]
    end
  end

  describe "structure" do
    test "rejects non-zips and truncated archives" do
      good = zip([[name: "a.milk", data: "a=1"]])

      assert open("") == {:error, :not_a_zip}
      assert open("not a zip at all") == {:error, :not_a_zip}
      assert open(binary_part(good, 0, byte_size(good) - 1)) == {:error, :not_a_zip}
      assert open(binary_part(good, 0, div(byte_size(good), 2))) == {:error, :not_a_zip}
    end

    test "rejects trailing bytes after the EOCD comment and data before the archive" do
      good = zip([[name: "a.milk", data: "a=1"]])
      assert open(good <> "x") == {:error, :not_a_zip}

      # Offsets are relative to the prefix-less archive, so the CD no longer
      # ends where the EOCD starts.
      assert open("junk" <> good) == {:error, :bad_central_directory}
    end

    test "rejects a central directory that disagrees with the EOCD count" do
      entries = [[name: "a.milk", data: "a=1"], [name: "b.milk", data: "b=1"]]
      assert open(zip(entries, count: 1, on_disk: 1)) == {:error, :bad_central_directory}
      assert open(zip(entries, count: 3, on_disk: 3)) == {:error, :bad_central_directory}
    end

    test "rejects multi-disk archives" do
      entry = [name: "a.milk", data: "a=1"]
      assert open(zip([entry], disk: 1)) == {:error, :multi_disk}
      assert open(zip([entry], cd_disk: 1)) == {:error, :multi_disk}
      assert open(zip([entry], on_disk: 0)) == {:error, :multi_disk}
      assert open(zip([Keyword.put(entry, :disk, 1)])) == {:error, :multi_disk}
    end

    test "rejects ZIP64 markers" do
      entry = [name: "a.milk", data: "a=1"]
      zip64_extra = <<0x0001::little-16, 8::little-16, 3::little-64>>

      assert open(zip([entry], zip64_locator: true)) == {:error, :zip64}
      assert open(zip([entry], count: 0xFFFF, on_disk: 0xFFFF)) == {:error, :zip64}
      assert open(zip([entry ++ [usize: 0xFFFFFFFF]])) == {:error, :zip64}
      assert open(zip([entry ++ [csize: 0xFFFFFFFF]])) == {:error, :zip64}
      assert open(zip([entry ++ [offset: 0xFFFFFFFF]])) == {:error, :zip64}
      assert open(zip([entry ++ [cd_extra: zip64_extra]])) == {:error, :zip64}
      assert open(zip([entry ++ [local_extra: zip64_extra]])) == {:error, :zip64}
    end

    test "rejects malformed extra fields" do
      assert open(zip([[name: "a.milk", data: "a=1", cd_extra: <<1, 2, 9, 0>>]])) ==
               {:error, :bad_central_directory}
    end

    test "allows 256 entries, rejects 257 (directories count)" do
      entries = fn n -> for i <- 1..n, do: [name: "d#{i}/"] end

      assert {:ok, zip} = open(zip(entries.(256)))
      assert length(Zip.entries(zip)) == 256
      assert open(zip(entries.(257))) == {:error, :too_many_entries}
    end

    test "rejects more than 32 MiB declared in total" do
      half = :binary.copy(<<0>>, 16 * 1024 * 1024 + 1)

      assert open(zip([[name: "a.png", data: half], [name: "b.png", data: half]])) ==
               {:error, :too_large}

      assert open(zip([[name: "a.milk", data: "a=1"]]), max_total: 2) == {:error, :too_large}
    end
  end

  describe "entries" do
    test "rejects unsafe paths instead of rewriting them" do
      for name <- [
            "../x.milk",
            "a/../../x.milk",
            "/abs.milk",
            "a\\b.milk",
            "\\x.milk",
            "C:x.milk",
            "C:/x.milk",
            "a//b.milk",
            "./a.milk",
            "a/./b.milk",
            "a/..",
            "a\0b.milk",
            "a\nb.milk",
            "a\x7fb.milk",
            "",
            "/",
            "a//"
          ] do
        assert open(zip([[name: name, data: "a=1"]])) == {:error, {:unsafe_path, printable(name)}},
               "expected #{inspect(name)} to be rejected"
      end
    end

    test "rejects symlinks and other non-regular files" do
      for mode <- [0o120777, 0o010644, 0o020644, 0o060644, 0o140755] do
        assert open(zip([[name: "a.milk", data: "a=1", ext_attr: mode <<< 16]])) ==
                 {:error, {:not_regular_file, "a.milk"}}
      end

      # A directory mode on a file name, and a file mode on a directory name.
      assert open(zip([[name: "a.milk", ext_attr: 0o040755 <<< 16]])) ==
               {:error, {:not_regular_file, "a.milk"}}

      assert open(zip([[name: "d/", ext_attr: 0o100644 <<< 16]])) ==
               {:error, {:not_regular_file, "d/"}}
    end

    test "rejects encrypted entries" do
      for flag <- [0x0001, 0x0040, 0x2000] do
        assert open(zip([[name: "a.milk", data: "a=1", flags: 0x0800 ||| flag]])) ==
                 {:error, {:encrypted, "a.milk"}}
      end
    end

    test "rejects methods other than stored and deflate" do
      for code <- [1, 9, 12, 14, 93, 99] do
        assert open(zip([[name: "a.milk", data: "a=1", method_code: code]])) ==
                 {:error, {:unsupported_method, "a.milk"}}
      end
    end

    test "rejects names that are not UTF-8" do
      assert open(zip([[name: <<"caf", 0xE9, ".milk">>, data: "a=1"]])) ==
               {:error, {:name_encoding, "caf?.milk"}}
    end

    test "rejects duplicates ignoring case and NFC/NFD" do
      assert open(zip([[name: "a.milk", data: "1"], [name: "A.MILK", data: "2"]])) ==
               {:error, {:duplicate, "A.MILK"}}

      nfd = "cafe\u0301.milk"

      assert open(zip([[name: "café.milk", data: "1"], [name: nfd, data: "2"]])) ==
               {:error, {:duplicate, nfd}}

      # Same basename in different folders is the caller's concern.
      assert {:ok, _} = open(zip([[name: "x/a.milk", data: "1"], [name: "y/a.milk", data: "2"]]))
    end

    test "rejects implausible sizes" do
      assert open(zip([[name: "a.milk", data: "abc", usize: 4]])) ==
               {:error, {:bad_sizes, "a.milk"}}

      assert open(zip([[name: "d/", data: "abc"]])) == {:error, {:bad_sizes, "d/"}}

      huge = :crypto.strong_rand_bytes(2_000)

      assert open(zip([[name: "a.png", data: "x", method: :deflate, compressed: huge, usize: 1]])) ==
               {:error, {:bad_sizes, "a.png"}}
    end

    test "rejects a deflate bomb by ratio" do
      zeros = :binary.copy(<<0>>, 4 * 1024 * 1024)

      assert open(zip([[name: "a.png", data: zeros, method: :deflate]])) ==
               {:error, {:ratio, "a.png"}}
    end

    test "rejects a local header whose name, flags or method differ" do
      entry = [name: "a.milk", data: "a=1"]

      assert open(zip([entry ++ [local_name: "../evil.milk"]])) ==
               {:error, {:header_mismatch, "a.milk"}}

      assert open(zip([entry ++ [local_name: "A.milk"]])) ==
               {:error, {:header_mismatch, "a.milk"}}

      assert open(zip([entry ++ [local_flags: 0]])) == {:error, {:header_mismatch, "a.milk"}}
      assert open(zip([entry ++ [local_method: 8]])) == {:error, {:header_mismatch, "a.milk"}}
      assert open(zip([entry ++ [local_crc: 1]])) == {:error, {:header_mismatch, "a.milk"}}
      # Zero local values are only allowed with a data descriptor.
      assert open(zip([entry ++ [local_csize: 0]])) == {:error, {:header_mismatch, "a.milk"}}
    end

    test "rejects a central directory pointing at no local header" do
      bin = zip([[name: "a.milk", data: "a=1"], [name: "b.milk", data: "b=1", offset: 1]])
      assert open(bin) == {:error, {:bad_local_header, "b.milk"}}
    end

    test "rejects overlapping entries" do
      # a's declared data runs into b's local header.
      data = String.duplicate("x=1\n", 50)
      compressed = deflate(data)

      bin =
        zip([
          [name: "a.milk", data: data, method: :deflate, csize: byte_size(compressed) + 20],
          [name: "b.milk", data: "b=1"]
        ])

      assert open(bin) == {:error, {:overlap, "b.milk"}}

      # A second central record pointing at the first entry's local header.
      shared = zip([[name: "a.milk", data: "a=1"], [name: "b.milk", data: "a=1", offset: 0]])
      assert open(shared) == {:error, {:header_mismatch, "b.milk"}}

      # Data running into the central directory.
      compressed = deflate("a=1")

      bin =
        zip([[name: "a.milk", data: "a=1", method: :deflate, csize: byte_size(compressed) + 10]])

      assert open(bin) == {:error, {:overlap, "a.milk"}}
    end
  end

  describe "read/2" do
    test "rejects a deflate stream that inflates past its declared size" do
      data = String.duplicate("zoom=1.0\n", 1_000)
      bin = zip([[name: "a.milk", data: data, method: :deflate, usize: 100]])

      {:ok, zip} = open(bin)
      [entry] = Zip.entries(zip)
      assert Zip.read(zip, entry) == {:error, {:size_mismatch, "a.milk"}}
    end

    test "stops a lying bomb at the declared size" do
      # 20 MiB of zeros deflate to ~20 KiB; 1 MiB declared passes the ratio
      # cap, and reading stops right after it.
      zeros = :binary.copy(<<0>>, 20 * 1024 * 1024)
      compressed = deflate(zeros)
      usize = 1024 * 1024

      bin =
        zip([[name: "a.png", data: <<>>, method: :deflate, compressed: compressed, usize: usize]])

      {:ok, zip} = open(bin)
      [entry] = Zip.entries(zip)
      assert Zip.read(zip, entry) == {:error, {:size_mismatch, "a.png"}}
    end

    test "rejects output shorter than declared" do
      bin = zip([[name: "a.milk", data: "a=1", method: :deflate, usize: 10]])
      {:ok, zip} = open(bin)
      [entry] = Zip.entries(zip)
      assert Zip.read(zip, entry) == {:error, {:size_mismatch, "a.milk"}}
    end

    test "rejects a CRC mismatch" do
      for method <- [:stored, :deflate] do
        bin = zip([[name: "a.milk", data: "a=1", method: method, crc: 12_345]])
        {:ok, zip} = open(bin)
        [entry] = Zip.entries(zip)
        assert Zip.read(zip, entry) == {:error, {:crc_mismatch, "a.milk"}}
      end
    end

    test "rejects a corrupt deflate stream" do
      bin =
        zip([[name: "a.milk", data: "a=1", method: :deflate, compressed: <<0xFF, 0xFF, 0xFF>>]])

      {:ok, zip} = open(bin)
      [entry] = Zip.entries(zip)
      assert Zip.read(zip, entry) == {:error, {:corrupt, "a.milk"}}

      # A stream that never ends.
      partial = binary_part(deflate(String.duplicate("abc", 1000)), 0, 5)
      bin = zip([[name: "b.milk", data: "abc", method: :deflate, compressed: partial, usize: 3]])
      {:ok, zip} = open(bin)
      [entry] = Zip.entries(zip)
      assert {:error, {_reason, "b.milk"}} = Zip.read(zip, entry)
    end
  end

  test "error names are display-safe" do
    name = "a\u202Eklim.png/../x"
    assert {:error, {:unsafe_path, safe}} = open(zip([[name: name, data: "1"]]))
    refute safe =~ "\u202E"
  end

  defp printable(name), do: UploadCheck.printable(name)
end
