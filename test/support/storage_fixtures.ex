defmodule UniversalProxy.StorageFixtures do
  @moduledoc """
  Builds fake `/sys/class/block` trees and filesystem-magic byte
  fixtures for `UniversalProxy.Storage.Probe` tests.

  Unlike `AudioFixtures` (which only builds in-memory sample maps),
  `Probe` reads real files/symlinks, so these helpers materialise a
  small sysfs-shaped directory tree under a tmp dir per test — mirroring
  the inline `File.mkdir_p!`/`File.ln_s!` fixtures in
  `Audio.EnumerateTest`, just factored out since `Probe` fixtures need
  more moving parts (disk + USB device chain + partitions).

  The shape matches a real kernel, because `Probe` depends on it:

    * the class entry (`<sys_root>/sda`) is a **symlink** into a devices
      tree, not a directory;
    * `size` and the partition children live in the real block directory
      the class entry points at;
    * the `device` symlink sits inside that real directory and is
      relative to it (`../../../0:0:0:0`), so its raw target contains no
      USB segment — the bus path and `idVendor`/`idProduct`/`serial` are
      only reachable through the resolved ancestry.

  The one liberty taken is depth: a real `/sys/class/block/sda` points at
  `../../devices/…`, while here the devices tree is a sibling of
  `sys_root` (`../devices/…`) so any `sys_root` a test picks works. The
  relative-resolution mechanics being exercised are identical.
  """

  @block_size 4096

  # -- sysfs tree builders --

  @doc """
  Create a USB-backed whole disk `name` (e.g. "sda", "nvme0n1"): a real
  block directory under a devices tree, a class-entry symlink to it at
  `<sys_root>/<name>`, and a relative `device` symlink into the SCSI
  target chain hanging off the USB interface of the device node that
  carries `idVendor`/`idProduct`/`serial` at `slot_sub` (e.g. "1-1.3").
  Returns `:ok`.

  Options: `:sectors` (default ~10 GiB worth of 512-byte sectors),
  `:slot_sub`, `:vendor_id`, `:product_id`, and `:serial` — the USB
  `serial` attribute the device node publishes beside its ids. Pass
  `serial: nil` for a stick that publishes none (cheap clones), which
  writes no `serial` file at all.
  """
  def put_usb_disk!(sys_root, name, opts \\ []) do
    sectors = Keyword.get(opts, :sectors, 20_971_520)
    slot_sub = Keyword.get(opts, :slot_sub, "1-1.3")
    vendor_id = Keyword.get(opts, :vendor_id, 0x0BDA)
    product_id = Keyword.get(opts, :product_id, 0x0316)
    serial = Keyword.get(opts, :serial, "0123456789ABCDEF")

    # The USB device node: idVendor/idProduct/serial live here, above the
    # bound interface, which is why Probe walks the resolved ancestry.
    usb_path = ["platform", "soc", "usb1", slot_sub]
    usb_dir = Path.join([devices_root(sys_root) | usb_path])
    File.mkdir_p!(usb_dir)
    File.write!(Path.join(usb_dir, "idVendor"), hex4(vendor_id))
    File.write!(Path.join(usb_dir, "idProduct"), hex4(product_id))
    # The kernel newline-terminates these attributes, so the fixture does
    # too — reading one back untrimmed is a bug the tests must be able to
    # catch.
    if serial, do: File.write!(Path.join(usb_dir, "serial"), "#{serial}\n")

    scsi_path = usb_path ++ ["#{slot_sub}:1.0", "host0", "target0:0:0", "0:0:0:0"]
    put_disk!(sys_root, name, scsi_path, sectors)
  end

  @doc """
  Create a whole disk `name` with a device chain that carries no
  `idVendor` anywhere (an internal SD/eMMC/SATA disk) — `Probe` must
  exclude it. Same symlink shape as `put_usb_disk!/3`. Returns `:ok`.
  """
  def put_internal_disk!(sys_root, name, opts \\ []) do
    sectors = Keyword.get(opts, :sectors, 41_943_040)
    scsi_path = ["platform", "soc", "ahci", "host0", "target0:0:0", "0:0:0:0"]

    put_disk!(sys_root, name, scsi_path, sectors)
  end

  @doc """
  Add a partition child (e.g. "sda1", "nvme0n1p1") to an already created
  disk's **real** block directory, with its own `size` file. Returns
  `:ok`.
  """
  def put_partition!(sys_root, disk_name, partition_name, opts \\ []) do
    sectors = Keyword.get(opts, :sectors, 2_097_152)

    part_dir = Path.join(block_dir(sys_root, disk_name), partition_name)
    File.mkdir_p!(part_dir)
    File.write!(Path.join(part_dir, "size"), "#{sectors}\n")

    :ok
  end

  @doc """
  The raw (unresolved) target of a disk's inner `device` symlink — what
  a test asserts on to show the USB bus path cannot come from the link
  text itself.
  """
  def device_link_target!(sys_root, name) do
    File.read_link!(Path.join(block_dir(sys_root, name), "device"))
  end

  # The real block directory (`…/0:0:0:0/block/sda`) plus the class-entry
  # symlink that points at it, and the `device` symlink back up to the
  # bus device the disk hangs off — three levels up, exactly as the
  # kernel writes it.
  defp put_disk!(sys_root, name, device_path, sectors) do
    block_dir = Path.join([devices_root(sys_root) | device_path] ++ ["block", name])
    File.mkdir_p!(block_dir)
    File.write!(Path.join(block_dir, "size"), "#{sectors}\n")

    File.ln_s!(
      Path.join(["..", "..", "..", List.last(device_path)]),
      Path.join(block_dir, "device")
    )

    File.mkdir_p!(sys_root)
    class_target = Path.join(["..", "devices"] ++ device_path ++ ["block", name])
    File.ln_s!(class_target, Path.join(sys_root, name))

    :ok
  end

  # Sibling of the class dir; see the moduledoc on depth.
  defp devices_root(sys_root), do: Path.join(Path.dirname(sys_root), "devices")

  # Where `size` and the partition children really live, class-entry
  # symlink resolved.
  defp block_dir(sys_root, name) do
    entry = Path.join(sys_root, name)

    case File.read_link(entry) do
      {:ok, target} -> entry |> Path.dirname() |> Path.join(target) |> Path.expand()
      {:error, _reason} -> entry
    end
  end

  defp hex4(id) do
    id
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(4, "0")
    |> Kernel.<>("\n")
  end

  # -- filesystem-magic byte fixtures (4 KiB, zero-padded) --

  @doc "First 4 KiB of an ext4 superblock: LE magic 0xEF53 at offset 0x438."
  def ext4_bytes, do: block([{0x438, <<0x53, 0xEF>>}])

  @doc """
  First 4 KiB of an exFAT boot sector: OEM name `"EXFAT   "` at offset 3
  plus the `VolumeFlags` u16 at offset 106.

  `dirty: true` sets the `VolumeDirty` bit (0x0002); the default leaves
  the flags clear. `active_fat: true` sets bit 0 instead, which is the
  bit a naive "flags are non-zero" check would misread as dirty.
  """
  def exfat_bytes(opts \\ []) do
    dirty = if Keyword.get(opts, :dirty, false), do: 0x0002, else: 0x0000
    active_fat = if Keyword.get(opts, :active_fat, false), do: 0x0001, else: 0x0000

    block([{3, "EXFAT   "}, {106, <<Bitwise.bor(dirty, active_fat)::little-16>>}])
  end

  @doc "First 4 KiB of an NTFS boot sector: OEM name \"NTFS    \" at offset 3."
  def ntfs_bytes, do: block([{3, "NTFS    "}])

  @doc """
  First 4 KiB of a FAT boot sector: plausible bytes-per-sector (512) at
  offset 0x0B plus the 0x55AA BPB signature at offset 510.
  """
  def vfat_bytes, do: block([{0x0B, <<0x00, 0x02>>}, {510, <<0x55, 0xAA>>}])

  @doc "4 KiB of bytes matching none of the recognised superblock magics."
  def garbage_bytes, do: :binary.copy("x", @block_size)

  @doc "A binary shorter than any recognised magic offset — always :unknown."
  def short_bytes, do: <<1, 2, 3>>

  # -- FAT16/FAT32 volume images --
  #
  # The clean-shutdown bit is in FAT[1], past the reserved sectors, so
  # these fixtures are whole volume *images* rather than just a head: a
  # test slices the head out with `head/1` and reads the flag at the
  # offset `Probe.fat_dirty_offset/1` computes, exercising the same two
  # reads `Storage.Server` performs. The geometry is chosen so the FAT
  # spec's cluster count lands in each type's range — 261 628 clusters for
  # FAT32, 16 342 for FAT16.

  # 32 reserved sectors of 512 bytes puts FAT[1] at 16 388 — deliberately
  # outside the 4 KiB head, which is the case the second read exists for.
  @fat32_bps 512
  @fat32_reserved 32

  # One reserved sector is what a real FAT16 volume has, which puts its
  # FAT[1] at 514 — inside the head, yet still read through the same seam.
  @fat16_bps 512
  @fat16_reserved 1

  @doc """
  A FAT32 volume image, long enough to hold FAT[1]. `dirty: true` clears
  bit 27 (`CLEAN_SHUT`) of FAT[1]; the default leaves it set.
  """
  def fat32_image(opts \\ []) do
    entry = if Keyword.get(opts, :dirty, false), do: 0x07FFFFFF, else: 0x0FFFFFFF
    fat_start = @fat32_reserved * @fat32_bps

    image(fat_start + @fat32_bps, [
      {0x0B, <<@fat32_bps::little-16>>},
      {0x0D, <<8>>},
      {0x0E, <<@fat32_reserved::little-16>>},
      {0x10, <<2>>},
      {0x11, <<0::little-16>>},
      {0x13, <<0::little-16>>},
      {0x16, <<0::little-16>>},
      {0x20, <<2_097_152::little-32>>},
      {0x24, <<2_048::little-32>>},
      {510, <<0x55, 0xAA>>},
      {fat_start, <<0x0FFFFFF8::little-32>>},
      {fat_start + 4, <<entry::little-32>>}
    ])
  end

  @doc "First 4 KiB of `fat32_image/1` — what a head read returns."
  def fat32_bytes(opts \\ []), do: head(fat32_image(opts))

  @doc """
  A FAT16 volume image, long enough to hold FAT[1]. `dirty: true` clears
  bit 15 of FAT[1]; the default leaves it set.
  """
  def fat16_image(opts \\ []) do
    entry = if Keyword.get(opts, :dirty, false), do: 0x7FFF, else: 0xFFFF
    fat_start = @fat16_reserved * @fat16_bps

    image(@block_size + @fat16_bps, [
      {0x0B, <<@fat16_bps::little-16>>},
      {0x0D, <<4>>},
      {0x0E, <<@fat16_reserved::little-16>>},
      {0x10, <<2>>},
      {0x11, <<512::little-16>>},
      {0x13, <<65_535::little-16>>},
      {0x16, <<64::little-16>>},
      {0x20, <<0::little-32>>},
      {0x24, <<0::little-32>>},
      {510, <<0x55, 0xAA>>},
      {fat_start, <<0xFFF8::little-16>>},
      {fat_start + 2, <<entry::little-16>>}
    ])
  end

  @doc "First 4 KiB of `fat16_image/1` — what a head read returns."
  def fat16_bytes(opts \\ []), do: head(fat16_image(opts))

  @doc """
  A FAT12 volume image (small enough that the cluster count lands under
  4085), which has no clean-shutdown bit at all.
  """
  def fat12_image(_opts \\ []) do
    fat_start = 512

    image(@block_size, [
      {0x0B, <<512::little-16>>},
      {0x0D, <<1>>},
      {0x0E, <<1::little-16>>},
      {0x10, <<2>>},
      {0x11, <<224::little-16>>},
      {0x13, <<2_880::little-16>>},
      {0x16, <<9::little-16>>},
      {510, <<0x55, 0xAA>>},
      {fat_start, <<0xFFF0::little-16>>}
    ])
  end

  @doc "First 4 KiB of `fat12_image/1`."
  def fat12_bytes(opts \\ []), do: head(fat12_image(opts))

  @doc "The first 4 KiB of an image — the caller's head read."
  def head(image), do: binary_part(image, 0, min(@block_size, byte_size(image)))

  @doc "The `length` bytes at `offset` — the caller's second read."
  def read_at(image, offset, length), do: binary_part(image, offset, length)

  defp block(patches), do: image(@block_size, patches)

  defp image(size, patches) do
    Enum.reduce(patches, :binary.copy(<<0>>, size), &patch/2)
  end

  defp patch({offset, bytes}, acc) do
    prefix = binary_part(acc, 0, offset)
    suffix_start = offset + byte_size(bytes)
    suffix = binary_part(acc, suffix_start, byte_size(acc) - suffix_start)
    prefix <> bytes <> suffix
  end
end
