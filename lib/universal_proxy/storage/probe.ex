defmodule UniversalProxy.Storage.Probe do
  @moduledoc """
  Discover external USB storage drives and sniff their filesystem type,
  without shelling out and without ever raising.

  The busybox on target ships `mount`/`umount`/`df` but no `blkid`,
  `sync`, `fdisk`, or `mkfs.*` (see `nerves_system_br`'s
  `board/nerves-common/busybox.config`). So there is no tool to ask
  "what partitions exist" or "what filesystem is this" — both have to
  be derived directly:

    * Partitions come from `/sys/class/block/<disk>/<disk>N` (or
      `<disk>pN` for NVMe) child directories — the kernel always
      publishes these regardless of userspace tooling.
    * Filesystem type comes from sniffing superblock magic bytes in the
      first 4 KiB of the device/partition (ext4's magic at 0x438,
      exFAT/NTFS's OEM name field at offset 3, vfat's BPB boot
      signature at 510) — the same bytes `blkid` itself would read.

  `list_drives/1` mirrors `UniversalProxy.Audio.Enumerate`'s
  `:audio_sys_root` seam: the sysfs root is overridable via
  `Application.get_env(:universal_proxy, :storage_sys_root, ...)` (and
  via an explicit `:sys_root` option, which wins over the app env), so
  this whole module is exercised on the host against synthesised
  fixture trees. `fs_type/1` and `first_data_partition/1` take plain
  binaries/maps and are pure — no filesystem access at all — so the
  superblock-sniffing logic itself needs no fixture tree.

  A drive whose `device` symlink has no `idVendor` anywhere among its
  ancestors is an internal disk (SD card, eMMC, SATA/PCIe) and is
  excluded — this subsystem only cares about removable USB storage.

  ## Why the class entry is resolved first

  `/sys/class/block/sda` is itself a symlink into
  `/sys/devices/…/block/sda`, and the `device` symlink *inside* that
  directory is relative to the **real** location
  (`device -> ../../../0:0:0:0`). Its raw target therefore carries no USB
  segment at all: the bus path and the `idVendor`/`idProduct` files only
  appear once both links have been resolved. Walking the lexical class
  path instead yields nothing, so every USB drive would look internal.
  """

  @type fs_type :: :ext4 | :exfat | :ntfs3 | :vfat | :unknown

  @type partition_info :: %{
          name: String.t(),
          dev_path: String.t(),
          size_bytes: non_neg_integer()
        }

  @type drive_info :: %{
          name: String.t(),
          dev_path: String.t(),
          size_bytes: non_neg_integer(),
          slot_sub: String.t() | nil,
          vendor_id: non_neg_integer(),
          product_id: non_neg_integer(),
          partitions: [partition_info()]
        }

  @sector_bytes 512
  @max_ancestor_depth 20

  # `sd[a-z]+` (sda, sdaa, …) and `nvme<ctrl>n<ns>` whole disks only —
  # anchored so a partition child (`sda1`, `nvme0n1p1`) never matches.
  @whole_disk_re ~r/^(?:sd[a-z]+|nvme\d+n\d+)$/

  # -- Drive enumeration --

  @doc """
  List external USB whole disks under the sysfs block root, each with
  its recognised partitions. Never raises; an absent or unreadable
  root simply yields `[]`.
  """
  @spec list_drives(keyword()) :: [drive_info()]
  def list_drives(opts \\ []) do
    sys_root = Keyword.get(opts, :sys_root, sys_root())

    case File.ls(sys_root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&whole_disk?/1)
        |> Enum.flat_map(&build_drive(&1, sys_root))
        |> Enum.sort_by(& &1.name)

      {:error, _reason} ->
        []
    end
  end

  defp whole_disk?(name), do: Regex.match?(@whole_disk_re, name)

  defp build_drive(name, sys_root) do
    case usb_ancestry(sys_root, name) do
      nil ->
        []

      {slot_sub, vendor_id, product_id} ->
        disk_dir = Path.join(sys_root, name)

        [
          %{
            name: name,
            dev_path: "/dev/#{name}",
            size_bytes: read_size(disk_dir),
            slot_sub: slot_sub,
            vendor_id: vendor_id,
            product_id: product_id,
            partitions: list_partitions(sys_root, name)
          }
        ]
    end
  end

  # -- Partition enumeration --

  defp list_partitions(sys_root, disk_name) do
    disk_dir = Path.join(sys_root, disk_name)
    partition_re = partition_regex(disk_name)

    case File.ls(disk_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(partition_re, &1))
        |> Enum.map(&build_partition(disk_dir, &1))
        |> Enum.sort_by(&partition_number/1)

      {:error, _reason} ->
        []
    end
  end

  defp partition_regex(disk_name) do
    if String.match?(disk_name, ~r/^nvme\d+n\d+$/) do
      ~r/^#{Regex.escape(disk_name)}p\d+$/
    else
      ~r/^#{Regex.escape(disk_name)}\d+$/
    end
  end

  defp build_partition(disk_dir, name) do
    %{
      name: name,
      dev_path: "/dev/#{name}",
      size_bytes: read_size(Path.join(disk_dir, name))
    }
  end

  # Trailing digit run in the partition name — works for both "sda1"
  # (-> 1) and "nvme0n1p3" (-> 3) since `$` anchors past the digits
  # embedded earlier in the disk name.
  defp partition_number(%{name: name}) do
    case Regex.run(~r/(\d+)$/, name) do
      [_, digits] -> String.to_integer(digits)
      _ -> 0
    end
  end

  # -- Size --

  defp read_size(dir) do
    case File.read(Path.join(dir, "size")) do
      {:ok, content} ->
        case Integer.parse(String.trim(content)) do
          {sectors, ""} -> sectors * @sector_bytes
          _ -> 0
        end

      {:error, _reason} ->
        0
    end
  end

  # -- USB ancestry (slot_sub + vendor/product id) --

  # A USB-backed disk's `device` symlink resolves through the bound USB
  # interface (see `Audio.Enumerate.read_usb_port/2`) and down into the
  # SCSI/NVMe target chain. `idVendor`/`idProduct` live on the USB
  # *device* node itself, one or more levels above the interface, so both
  # the bus path and the ids come from the **resolved** device directory's
  # own ancestry. A disk with no USB ancestry at all (internal
  # SD/eMMC/SATA/PCIe) never finds an `idVendor` and is excluded.
  @usb_iface_re ~r/^(\d+-[\d.]+):\d+\.\d+$/

  defp usb_ancestry(sys_root, name) do
    with {:ok, device_dir} <- resolve_device_dir(sys_root, name),
         {vendor_id, product_id} when is_integer(vendor_id) and is_integer(product_id) <-
           find_ids(device_dir) do
      {usb_bus_path(device_dir), vendor_id, product_id}
    else
      _ -> nil
    end
  end

  # `<class>/<name>` -> the absolute directory the `device` symlink inside
  # the real block directory points at.
  defp resolve_device_dir(sys_root, name) do
    link = Path.join(resolve_class_entry(sys_root, name), "device")

    case File.read_link(link) do
      {:ok, target} -> {:ok, expand_link_target(link, target)}
      {:error, reason} -> {:error, reason}
    end
  end

  # The class entry is a symlink on a real kernel; a plain directory is
  # accepted as-is so a flattened tree still enumerates.
  defp resolve_class_entry(sys_root, name) do
    entry = Path.join(sys_root, name)

    case File.read_link(entry) do
      {:ok, target} -> expand_link_target(entry, target)
      {:error, _reason} -> entry
    end
  end

  defp expand_link_target(link, target) do
    if String.starts_with?(target, "/") do
      target
    else
      link |> Path.dirname() |> Path.join(target) |> Path.expand()
    end
  end

  defp find_ids(path) do
    path
    |> ancestor_chain(@max_ancestor_depth)
    |> Enum.find_value({nil, nil}, &ids_at/1)
  end

  defp ids_at(dir) do
    case read_hex(Path.join(dir, "idVendor")) do
      nil -> nil
      vendor_id -> {vendor_id, read_hex(Path.join(dir, "idProduct"))}
    end
  end

  defp ancestor_chain(_path, 0), do: []

  defp ancestor_chain(path, depth) do
    parent = Path.dirname(path)

    if parent == path do
      [path]
    else
      [path | ancestor_chain(parent, depth - 1)]
    end
  end

  defp read_hex(path) do
    case File.read(path) do
      {:ok, content} ->
        case Integer.parse(String.trim(content), 16) do
          {value, ""} -> value
          _ -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  # The physical USB bus path ("1-1.3"), read from the resolved device
  # directory's path components — same technique as
  # `Audio.Enumerate.usb_bus_path/1`, applied to the resolved path because
  # the raw `device` target (`../../../0:0:0:0`) holds no USB segment.
  # `nil` when no interface segment is present (shouldn't happen once
  # `find_ids/1` has already succeeded, but this is independent string
  # parsing so it degrades gracefully rather than crashing).
  defp usb_bus_path(device_dir) do
    device_dir
    |> String.split("/")
    |> Enum.find_value(fn seg ->
      case Regex.run(@usb_iface_re, seg) do
        [_, bus] -> bus
        _ -> nil
      end
    end)
  end

  # -- Filesystem type sniffing --

  @ext4_magic_offset 0x438
  @oem_name_offset 3
  @bpb_sig_offset 510
  @bytes_per_sector_offset 0x0B

  @doc """
  Sniff a filesystem type from the first bytes of a device or
  partition (caller reads and supplies them — this function never
  touches a filesystem). Binaries shorter than the relevant magic
  offset are `:unknown`, never an error.
  """
  @spec fs_type(binary()) :: fs_type()
  def fs_type(bytes) when is_binary(bytes) do
    cond do
      ext4?(bytes) -> :ext4
      exfat?(bytes) -> :exfat
      ntfs?(bytes) -> :ntfs3
      vfat?(bytes) -> :vfat
      true -> :unknown
    end
  end

  defp ext4?(bytes) do
    byte_size(bytes) >= @ext4_magic_offset + 2 and
      binary_part(bytes, @ext4_magic_offset, 2) == <<0x53, 0xEF>>
  end

  defp exfat?(bytes) do
    byte_size(bytes) >= @oem_name_offset + 8 and
      binary_part(bytes, @oem_name_offset, 8) == "EXFAT   "
  end

  defp ntfs?(bytes) do
    byte_size(bytes) >= @oem_name_offset + 8 and
      binary_part(bytes, @oem_name_offset, 8) == "NTFS    "
  end

  defp vfat?(bytes) do
    byte_size(bytes) >= @bpb_sig_offset + 2 and
      binary_part(bytes, @bpb_sig_offset, 2) == <<0x55, 0xAA>> and
      not exfat?(bytes) and not ntfs?(bytes) and
      plausible_bytes_per_sector?(bytes)
  end

  defp plausible_bytes_per_sector?(bytes) do
    <<bytes_per_sector::little-16>> = binary_part(bytes, @bytes_per_sector_offset, 2)
    bytes_per_sector in [512, 1024, 2048, 4096]
  end

  # -- First data partition --

  @doc """
  Pick the lowest-numbered partition whose `:fs_type` is recognised
  (any value but `:unknown` or absent). If the drive has no
  partitions, the whole disk itself qualifies (a "superfloppy") when
  its own `:fs_type` is recognised. `nil` when nothing qualifies.

  Pure: the caller merges a sniffed `:fs_type` onto the drive map (and
  its partitions) beforehand — this function does no I/O.
  """
  @spec first_data_partition(map()) :: map() | nil
  def first_data_partition(%{partitions: []} = drive) do
    if recognised?(Map.get(drive, :fs_type)), do: drive, else: nil
  end

  def first_data_partition(%{partitions: partitions}) do
    partitions
    |> Enum.filter(&recognised?(Map.get(&1, :fs_type)))
    |> Enum.min_by(&partition_number/1, fn -> nil end)
  end

  defp recognised?(nil), do: false
  defp recognised?(:unknown), do: false
  defp recognised?(_fs_type), do: true

  defp sys_root, do: Application.get_env(:universal_proxy, :storage_sys_root, "/sys/class/block")
end
