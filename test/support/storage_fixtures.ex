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
  """

  @block_size 4096

  # -- sysfs tree builders --

  @doc """
  Create a USB-backed whole disk `name` (e.g. "sda", "nvme0n1") under
  `sys_root`, with a `size` file and a `device` symlink resolving
  through a USB interface node that carries `idVendor`/`idProduct` at
  `slot_sub` (e.g. "1-1.3"). Returns `:ok`.

  Options: `:sectors` (default ~10 GiB worth of 512-byte sectors),
  `:slot_sub`, `:vendor_id`, `:product_id`.
  """
  def put_usb_disk!(sys_root, name, opts \\ []) do
    sectors = Keyword.get(opts, :sectors, 20_971_520)
    slot_sub = Keyword.get(opts, :slot_sub, "1-1.3")
    vendor_id = Keyword.get(opts, :vendor_id, 0x0BDA)
    product_id = Keyword.get(opts, :product_id, 0x0316)

    disk_dir = Path.join(sys_root, name)
    File.mkdir_p!(disk_dir)
    File.write!(Path.join(disk_dir, "size"), "#{sectors}\n")

    device_dir = Path.join([sys_root, "usbdev", slot_sub])
    iface_name = "#{slot_sub}:0.0"
    File.mkdir_p!(Path.join(device_dir, iface_name))
    File.write!(Path.join(device_dir, "idVendor"), hex4(vendor_id))
    File.write!(Path.join(device_dir, "idProduct"), hex4(product_id))

    target = Path.join(["..", "usbdev", slot_sub, iface_name])
    File.ln_s!(target, Path.join(disk_dir, "device"))

    :ok
  end

  @doc """
  Create a whole disk `name` with a device chain that carries no
  `idVendor` anywhere (an internal SD/eMMC/SATA disk) — `Probe` must
  exclude it. Returns `:ok`.
  """
  def put_internal_disk!(sys_root, name, opts \\ []) do
    sectors = Keyword.get(opts, :sectors, 41_943_040)

    disk_dir = Path.join(sys_root, name)
    File.mkdir_p!(disk_dir)
    File.write!(Path.join(disk_dir, "size"), "#{sectors}\n")

    scsi_dir = Path.join([sys_root, "platform", "target0:0:0", "0:0:0:0"])
    File.mkdir_p!(scsi_dir)

    target = Path.join(["..", "platform", "target0:0:0", "0:0:0:0"])
    File.ln_s!(target, Path.join(disk_dir, "device"))

    :ok
  end

  @doc """
  Add a partition child (e.g. "sda1", "nvme0n1p1") under an already
  created disk directory, with its own `size` file. Returns `:ok`.
  """
  def put_partition!(sys_root, disk_name, partition_name, opts \\ []) do
    sectors = Keyword.get(opts, :sectors, 2_097_152)

    part_dir = Path.join([sys_root, disk_name, partition_name])
    File.mkdir_p!(part_dir)
    File.write!(Path.join(part_dir, "size"), "#{sectors}\n")

    :ok
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

  @doc "First 4 KiB of an exFAT boot sector: OEM name \"EXFAT   \" at offset 3."
  def exfat_bytes, do: block([{3, "EXFAT   "}])

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

  defp block(patches), do: Enum.reduce(patches, zeroes(), &patch/2)

  defp zeroes, do: :binary.copy(<<0>>, @block_size)

  defp patch({offset, bytes}, acc) do
    prefix = binary_part(acc, 0, offset)
    suffix_start = offset + byte_size(bytes)
    suffix = binary_part(acc, suffix_start, @block_size - suffix_start)
    prefix <> bytes <> suffix
  end
end
