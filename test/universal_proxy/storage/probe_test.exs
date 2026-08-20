defmodule UniversalProxy.Storage.ProbeTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Storage.Probe
  alias UniversalProxy.StorageFixtures, as: Fixtures

  describe "list_drives/1" do
    @tag :tmp_dir
    test "returns [] when the sys root is absent", %{tmp_dir: tmp_dir} do
      sys_root = Path.join(tmp_dir, "sys")

      assert Probe.list_drives(sys_root: sys_root) == []
    end

    @tag :tmp_dir
    test "returns [] for an empty sys root", %{tmp_dir: tmp_dir} do
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(sys_root)

      assert Probe.list_drives(sys_root: sys_root) == []
    end

    @tag :tmp_dir
    test "ext4 stick with one partition", %{tmp_dir: tmp_dir} do
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(sys_root)

      Fixtures.put_usb_disk!(sys_root, "sda",
        sectors: 20_971_520,
        slot_sub: "1-1.3",
        vendor_id: 0x0BDA,
        product_id: 0x0316
      )

      Fixtures.put_partition!(sys_root, "sda", "sda1", sectors: 20_969_472)

      assert [drive] = Probe.list_drives(sys_root: sys_root)

      assert drive.name == "sda"
      assert drive.dev_path == "/dev/sda"
      assert drive.size_bytes == 20_971_520 * 512
      assert drive.slot_sub == "1-1.3"
      assert drive.vendor_id == 0x0BDA
      assert drive.product_id == 0x0316

      assert drive.partitions == [
               %{
                 name: "sda1",
                 dev_path: "/dev/sda1",
                 size_bytes: 20_969_472 * 512
               }
             ]
    end

    @tag :tmp_dir
    test "exFAT stick with an unknown second partition", %{tmp_dir: tmp_dir} do
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(sys_root)

      Fixtures.put_usb_disk!(sys_root, "sdb", slot_sub: "1-1.4")
      Fixtures.put_partition!(sys_root, "sdb", "sdb1")
      Fixtures.put_partition!(sys_root, "sdb", "sdb2")

      assert [drive] = Probe.list_drives(sys_root: sys_root)
      assert Enum.map(drive.partitions, & &1.name) == ["sdb1", "sdb2"]

      # Simulate the caller merging sniffed fs types before picking the
      # first data partition — Probe itself never reads device content.
      sniffed =
        drive
        |> Map.put(
          :partitions,
          Enum.map(drive.partitions, fn
            %{name: "sdb1"} = p -> Map.put(p, :fs_type, Probe.fs_type(Fixtures.exfat_bytes()))
            %{name: "sdb2"} = p -> Map.put(p, :fs_type, Probe.fs_type(Fixtures.garbage_bytes()))
          end)
        )

      assert Probe.first_data_partition(sniffed).name == "sdb1"
    end

    @tag :tmp_dir
    test "unpartitioned vfat superfloppy", %{tmp_dir: tmp_dir} do
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(sys_root)

      Fixtures.put_usb_disk!(sys_root, "sdc", slot_sub: "1-1.5")

      assert [drive] = Probe.list_drives(sys_root: sys_root)
      assert drive.partitions == []

      sniffed = Map.put(drive, :fs_type, Probe.fs_type(Fixtures.vfat_bytes()))
      assert Probe.first_data_partition(sniffed) == sniffed
    end

    @tag :tmp_dir
    test "NVMe-in-USB-enclosure (nvme0n1 with p1 partition)", %{tmp_dir: tmp_dir} do
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(sys_root)

      Fixtures.put_usb_disk!(sys_root, "nvme0n1", slot_sub: "2-1")
      Fixtures.put_partition!(sys_root, "nvme0n1", "nvme0n1p1")

      assert [drive] = Probe.list_drives(sys_root: sys_root)
      assert drive.name == "nvme0n1"
      assert drive.dev_path == "/dev/nvme0n1"
      assert drive.slot_sub == "2-1"

      assert [%{name: "nvme0n1p1", dev_path: "/dev/nvme0n1p1"}] = drive.partitions
    end

    @tag :tmp_dir
    test "a non-USB internal disk is excluded", %{tmp_dir: tmp_dir} do
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(sys_root)

      Fixtures.put_internal_disk!(sys_root, "sda")

      assert Probe.list_drives(sys_root: sys_root) == []
    end

    @tag :tmp_dir
    test "a mix of internal and USB disks only surfaces the USB one", %{tmp_dir: tmp_dir} do
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(sys_root)

      Fixtures.put_internal_disk!(sys_root, "sda")
      Fixtures.put_usb_disk!(sys_root, "sdb", slot_sub: "1-1.2")

      assert [drive] = Probe.list_drives(sys_root: sys_root)
      assert drive.name == "sdb"
    end

    @tag :tmp_dir
    test "ignores non-disk entries under the sys root", %{tmp_dir: tmp_dir} do
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(sys_root, "loop0"))
      File.mkdir_p!(Path.join(sys_root, "dm-0"))

      assert Probe.list_drives(sys_root: sys_root) == []
    end

    test "app env :storage_sys_root is honoured when no :sys_root opt is given" do
      Application.put_env(:universal_proxy, :storage_sys_root, "/does/not/exist")
      on_exit(fn -> Application.delete_env(:universal_proxy, :storage_sys_root) end)

      assert Probe.list_drives() == []
    end
  end

  describe "fs_type/1" do
    test "recognises ext4" do
      assert Probe.fs_type(Fixtures.ext4_bytes()) == :ext4
    end

    test "recognises exFAT" do
      assert Probe.fs_type(Fixtures.exfat_bytes()) == :exfat
    end

    test "recognises NTFS" do
      assert Probe.fs_type(Fixtures.ntfs_bytes()) == :ntfs3
    end

    test "recognises vfat" do
      assert Probe.fs_type(Fixtures.vfat_bytes()) == :vfat
    end

    test "garbage bytes are :unknown" do
      assert Probe.fs_type(Fixtures.garbage_bytes()) == :unknown
    end

    test "a binary shorter than any magic offset is :unknown" do
      assert Probe.fs_type(Fixtures.short_bytes()) == :unknown
    end

    test "an empty binary is :unknown" do
      assert Probe.fs_type(<<>>) == :unknown
    end

    test "a bare 0x55AA at 510 without a plausible bytes-per-sector is :unknown" do
      # BPB signature present, but the bytes-per-sector field is garbage
      # (not a power of two 512..4096) — the vfat sanity check must reject it.
      bytes =
        <<0>>
        |> :binary.copy(4096)
        |> replace_at(510, <<0x55, 0xAA>>)
        |> replace_at(0x0B, <<0x03, 0x00>>)

      assert Probe.fs_type(bytes) == :unknown
    end
  end

  defp replace_at(bin, offset, patch) do
    prefix = binary_part(bin, 0, offset)
    suffix_start = offset + byte_size(patch)
    suffix = binary_part(bin, suffix_start, byte_size(bin) - suffix_start)
    prefix <> patch <> suffix
  end

  describe "first_data_partition/1" do
    test "picks the lowest-numbered recognised partition" do
      drive = %{
        partitions: [
          %{name: "sda1", fs_type: :unknown},
          %{name: "sda2", fs_type: :ext4},
          %{name: "sda3", fs_type: :exfat}
        ]
      }

      assert Probe.first_data_partition(drive).name == "sda2"
    end

    test "ignores partitions with no :fs_type key at all" do
      drive = %{
        partitions: [
          %{name: "sda1"},
          %{name: "sda2", fs_type: :vfat}
        ]
      }

      assert Probe.first_data_partition(drive).name == "sda2"
    end

    test "nil when no partition is recognised" do
      drive = %{
        partitions: [
          %{name: "sda1", fs_type: :unknown},
          %{name: "sda2", fs_type: nil}
        ]
      }

      assert Probe.first_data_partition(drive) == nil
    end

    test "superfloppy: whole disk qualifies when it has no partitions and a recognised fs" do
      drive = %{partitions: [], fs_type: :vfat}
      assert Probe.first_data_partition(drive) == drive
    end

    test "nil for an unpartitioned disk with no recognised fs" do
      assert Probe.first_data_partition(%{partitions: [], fs_type: :unknown}) == nil
      assert Probe.first_data_partition(%{partitions: []}) == nil
    end
  end
end
