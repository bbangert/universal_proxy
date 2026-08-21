defmodule UniversalProxy.Storage.ProbeTest do
  # async: false — the app-env test below mutates the global
  # `:storage_sys_root` key, which every concurrently-running test would
  # see.
  use ExUnit.Case, async: false

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
        product_id: 0x0316,
        serial: "AA00BB11CC22"
      )

      Fixtures.put_partition!(sys_root, "sda", "sda1", sectors: 20_969_472)

      assert [drive] = Probe.list_drives(sys_root: sys_root)

      assert drive.name == "sda"
      assert drive.dev_path == "/dev/sda"
      assert drive.size_bytes == 20_971_520 * 512
      assert drive.slot_sub == "1-1.3"
      assert drive.vendor_id == 0x0BDA
      assert drive.product_id == 0x0316
      # Trimmed: the kernel newline-terminates the attribute, and the
      # serial is a settings-key component, so a stray "\n" would key the
      # drive differently than a later trimmed read of the same stick.
      assert drive.serial == "AA00BB11CC22"

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
    test "the bus path and ids come from the resolved ancestry, not the link text", %{
      tmp_dir: tmp_dir
    } do
      sys_root = Path.join([tmp_dir, "sys", "class", "block"])

      Fixtures.put_usb_disk!(sys_root, "sda", slot_sub: "1-1.3", vendor_id: 0x0BDA)

      # The shape the kernel really publishes: a symlinked class entry, and
      # a `device` link whose raw target names no USB segment at all — so
      # neither the bus path nor the ids can be read off the link text.
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(sys_root, "sda"))
      raw_target = Fixtures.device_link_target!(sys_root, "sda")
      assert raw_target == "../../../0:0:0:0"
      refute raw_target =~ "1-1.3"

      assert [%{slot_sub: "1-1.3", vendor_id: 0x0BDA, size_bytes: size}] =
               Probe.list_drives(sys_root: sys_root)

      assert size > 0
    end

    @tag :tmp_dir
    test "a stick that publishes no serial reports serial: nil", %{tmp_dir: tmp_dir} do
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(sys_root)

      # Cheap clone sticks omit the attribute entirely. The drive still
      # enumerates — it just keys with a nil serial, which is the weaker
      # identity Storage.Server's moduledoc documents.
      Fixtures.put_usb_disk!(sys_root, "sda", serial: nil)

      assert [%{slot_sub: "1-1.3", vendor_id: 0x0BDA, serial: nil}] =
               Probe.list_drives(sys_root: sys_root)
    end

    @tag :tmp_dir
    test "two same-model sticks are distinguished by their serials", %{tmp_dir: tmp_dir} do
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(sys_root)

      Fixtures.put_usb_disk!(sys_root, "sda", slot_sub: "1-1.3", serial: "FIRST-STICK")
      Fixtures.put_usb_disk!(sys_root, "sdb", slot_sub: "1-1.4", serial: "SECOND-STICK")

      assert [
               %{name: "sda", vendor_id: 0x0BDA, product_id: 0x0316, serial: "FIRST-STICK"},
               %{name: "sdb", vendor_id: 0x0BDA, product_id: 0x0316, serial: "SECOND-STICK"}
             ] = Probe.list_drives(sys_root: sys_root)
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
      # Restored, not deleted: the test env configures this key (see
      # config/test.exs) precisely so the application-tree Storage.Server
      # never enumerates the host's real disks, and deleting it would
      # uncover them for every test that runs after this one.
      previous = Application.fetch_env(:universal_proxy, :storage_sys_root)
      Application.put_env(:universal_proxy, :storage_sys_root, "/does/not/exist")

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:universal_proxy, :storage_sys_root, value)
          :error -> Application.delete_env(:universal_proxy, :storage_sys_root)
        end
      end)

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

  describe "dirty?/2 exFAT" do
    test "a clean volume has VolumeDirty clear" do
      assert Probe.dirty?(:exfat, Fixtures.exfat_bytes()) == false
    end

    test "a dirty volume has VolumeDirty set" do
      assert Probe.dirty?(:exfat, Fixtures.exfat_bytes(dirty: true)) == true
    end

    test "ActiveFat alone is not dirty" do
      # Bit 0 of VolumeFlags selects which FAT is live and says nothing
      # about cleanliness — a "flags are non-zero" check would get this
      # wrong on every volume that ever switched FATs.
      assert Probe.dirty?(:exfat, Fixtures.exfat_bytes(active_fat: true)) == false

      assert Probe.dirty?(:exfat, Fixtures.exfat_bytes(active_fat: true, dirty: true)) == true
    end

    test "a head too short to hold VolumeFlags is :unknown" do
      assert Probe.dirty?(:exfat, binary_part(Fixtures.exfat_bytes(), 0, 100)) == :unknown
    end

    test "the flag is in the head, so no second read is needed" do
      assert Probe.dirty_probe(Fixtures.exfat_bytes(dirty: true)) == nil
    end
  end

  describe "dirty?/2 for the filesystems with nothing to read" do
    test "ext4 is reported clean — it is fsck'd before every mount" do
      assert Probe.dirty?(:ext4, Fixtures.ext4_bytes()) == false
      assert Probe.dirty_probe(Fixtures.ext4_bytes()) == nil
    end

    test "NTFS is reported clean — a dirty volume mounts read-only" do
      assert Probe.dirty?(:ntfs3, Fixtures.ntfs_bytes()) == false
      assert Probe.dirty_probe(Fixtures.ntfs_bytes()) == nil
    end

    test "an unrecognised filesystem is :unknown, never false" do
      assert Probe.dirty?(:unknown, Fixtures.garbage_bytes()) == :unknown
      assert Probe.dirty?(nil, Fixtures.garbage_bytes()) == :unknown
      assert Probe.dirty_probe(Fixtures.garbage_bytes()) == nil
    end
  end

  describe "fat_dirty_offset/1" do
    test "FAT32: reserved_sectors * bytes_per_sector + 4, four bytes wide" do
      # The fixture's BPB: 512-byte sectors, 32 reserved.
      assert Probe.fat_dirty_offset(Fixtures.fat32_bytes()) == {:ok, 32 * 512 + 4, 4}
    end

    test "FAT16: reserved_sectors * bytes_per_sector + 2, two bytes wide" do
      # 512-byte sectors, 1 reserved.
      assert Probe.fat_dirty_offset(Fixtures.fat16_bytes()) == {:ok, 1 * 512 + 2, 2}
    end

    test "the FAT32 flag is outside the 4 KiB head — the second read is not optional" do
      assert {:ok, offset, _length} = Probe.fat_dirty_offset(Fixtures.fat32_bytes())
      assert offset > 4096
    end

    test "FAT12 has no clean-shutdown bit at all" do
      assert Probe.fat_dirty_offset(Fixtures.fat12_bytes()) == :error
      assert Probe.dirty_probe(Fixtures.fat12_bytes()) == nil
      assert Probe.dirty_at?(:vfat, Fixtures.fat12_bytes(), <<0xFF, 0xFF>>) == :unknown
    end

    test "an implausible BPB is :error, not a bogus offset" do
      # The bare vfat fixture has the 0x55AA signature and a plausible
      # sector size but zero reserved sectors and no FAT at all.
      assert Probe.fat_dirty_offset(Fixtures.vfat_bytes()) == :error
      assert Probe.dirty_probe(Fixtures.vfat_bytes()) == nil
    end

    test "a head shorter than the BPB is :error" do
      assert Probe.fat_dirty_offset(<<1, 2, 3>>) == :error
    end
  end

  describe "dirty?/2 + dirty_probe/1 + dirty_at?/3 for vfat" do
    test "FAT32 needs a second read, which the head alone cannot supply" do
      head = Fixtures.fat32_bytes()

      assert Probe.fs_type(head) == :vfat
      assert Probe.dirty?(:vfat, head) == :unknown
      assert Probe.dirty_probe(head) == {:read, 16_388, 4}
    end

    test "FAT32 clean: bit 27 of FAT[1] set" do
      image = Fixtures.fat32_image()
      head = Fixtures.head(image)

      assert {:read, offset, length} = Probe.dirty_probe(head)
      assert Probe.dirty_at?(:vfat, head, Fixtures.read_at(image, offset, length)) == false
    end

    test "FAT32 dirty: bit 27 of FAT[1] cleared" do
      image = Fixtures.fat32_image(dirty: true)
      head = Fixtures.head(image)

      assert {:read, offset, length} = Probe.dirty_probe(head)
      assert Probe.dirty_at?(:vfat, head, Fixtures.read_at(image, offset, length)) == true
    end

    test "FAT16 clean: bit 15 of FAT[1] set" do
      image = Fixtures.fat16_image()
      head = Fixtures.head(image)

      assert Probe.dirty_probe(head) == {:read, 514, 2}
      assert Probe.dirty_at?(:vfat, head, Fixtures.read_at(image, 514, 2)) == false
    end

    test "FAT16 dirty: bit 15 of FAT[1] cleared" do
      image = Fixtures.fat16_image(dirty: true)
      head = Fixtures.head(image)

      assert Probe.dirty_at?(:vfat, head, Fixtures.read_at(image, 514, 2)) == true
    end

    test "a short second read is :unknown, not a guess" do
      head = Fixtures.fat32_bytes()

      assert Probe.dirty_at?(:vfat, head, <<0xFF, 0xFF>>) == :unknown
      assert Probe.dirty_at?(:vfat, head, <<>>) == :unknown
    end

    test "dirty_at?/3 falls back to the head-only answer for non-vfat" do
      # A caller that reads bytes anyway (or replays a stale probe) still
      # gets the boot-sector verdict for exFAT.
      assert Probe.dirty_at?(:exfat, Fixtures.exfat_bytes(dirty: true), <<0, 0, 0, 0>>) == true
      assert Probe.dirty_at?(:ext4, Fixtures.ext4_bytes(), <<0, 0, 0, 0>>) == false
    end
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
