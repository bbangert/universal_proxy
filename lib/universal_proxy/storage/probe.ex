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

  ## Dirty-bit detection

  Every one of these filesystems records whether it was unmounted
  cleanly, and a volume that was yanked mid-write reports EIO on the
  next write rather than anything a mount-time log line makes visible.
  `dirty?/2` reads that record:

    * exFAT keeps `VolumeFlags` in the boot sector (offset 106), so its
      `VolumeDirty` bit is already in the 4 KiB head.
    * FAT16/FAT32 keep theirs in **FAT[1]**, past the reserved sectors
      and therefore usually outside the head. `dirty?/2` answers
      `:unknown` for vfat and `dirty_probe/1` says which bytes are still
      needed; the caller reads them through its own seam and finishes
      with `dirty_at?/3`. Everything stays pure.
    * ext4 answers `false` — it is `fsck`ed before every mount, so its
      superblock state is not what the drawer should report — and NTFS3
      answers `false` too, because the kernel refuses a dirty NTFS
      volume read-write and the resulting read-only mount is already
      surfaced.

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

  ## The USB serial is part of a drive's identity

  `idVendor`/`idProduct` describe a *model*, not a medium: two identical
  sticks in the same port are indistinguishable by them, so a settings key
  built from the port and the ids alone would carry an opt-in from one
  stick over to its replacement. The USB `serial` attribute — published by
  the very same device node that carries the ids, so it is read from the
  dir they were found in rather than searched for separately (a hub's
  serial one level up must never stand in for the stick's) — is the one
  per-medium identifier available here. Cheap clone sticks omit it
  entirely; those report `serial: nil`, and `Storage.Server`'s moduledoc
  documents what that costs.

  ## Why the class entry is resolved first

  `/sys/class/block/sda` is itself a symlink into
  `/sys/devices/…/block/sda`, and the `device` symlink *inside* that
  directory is relative to the **real** location
  (`device -> ../../../0:0:0:0`). Its raw target therefore carries no USB
  segment at all: the bus path and the `idVendor`/`idProduct` files only
  appear once both links have been resolved. Walking the lexical class
  path instead yields nothing, so every USB drive would look internal.
  """

  import Bitwise

  @type fs_type :: :ext4 | :exfat | :ntfs3 | :vfat | :unknown

  @typedoc """
  `true`/`false` when the filesystem's own record of its last unmount was
  readable, `:unknown` when it was not — either because the bytes holding
  it are outside the head (`dirty_probe/1` says which) or because this
  filesystem keeps no such record.
  """
  @type dirty :: boolean() | :unknown

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
          serial: String.t() | nil,
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

      {slot_sub, vendor_id, product_id, serial} ->
        disk_dir = Path.join(sys_root, name)

        [
          %{
            name: name,
            dev_path: "/dev/#{name}",
            size_bytes: read_size(disk_dir),
            slot_sub: slot_sub,
            vendor_id: vendor_id,
            product_id: product_id,
            serial: serial,
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

  # -- USB ancestry (slot_sub + vendor/product id + serial) --

  # A USB-backed disk's `device` symlink resolves through the bound USB
  # interface (see `Audio.Enumerate.read_usb_port/2`) and down into the
  # SCSI/NVMe target chain. `idVendor`/`idProduct`/`serial` live on the USB
  # *device* node itself, one or more levels above the interface, so both
  # the bus path and the attributes come from the **resolved** device
  # directory's own ancestry. A disk with no USB ancestry at all (internal
  # SD/eMMC/SATA/PCIe) never finds an `idVendor` and is excluded.
  @usb_iface_re ~r/^(\d+-[\d.]+):\d+\.\d+$/

  defp usb_ancestry(sys_root, name) do
    with {:ok, device_dir} <- resolve_device_dir(sys_root, name),
         {vendor_id, product_id, serial}
         when is_integer(vendor_id) and is_integer(product_id) <-
           find_usb_attrs(device_dir) do
      {usb_bus_path(device_dir), vendor_id, product_id, serial}
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

  defp find_usb_attrs(path) do
    path
    |> ancestor_chain(@max_ancestor_depth)
    |> Enum.find_value({nil, nil, nil}, &usb_attrs_at/1)
  end

  # `serial` is read from the dir the ids were found in, never searched up
  # the chain on its own: the hub above a serial-less stick publishes one,
  # and borrowing it would give every stick in that hub the same identity.
  defp usb_attrs_at(dir) do
    case read_hex(Path.join(dir, "idVendor")) do
      nil ->
        nil

      vendor_id ->
        {vendor_id, read_hex(Path.join(dir, "idProduct")), read_serial(dir)}
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

  # A stick with no `serial` attribute (or an empty one) is `nil`, not "",
  # so the absence is one value rather than two.
  defp read_serial(dir) do
    case File.read(Path.join(dir, "serial")) do
      {:ok, content} ->
        case String.trim(content) do
          "" -> nil
          serial -> serial
        end

      {:error, _reason} ->
        nil
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

  # -- Dirty-bit detection --

  # exFAT boot sector: VolumeFlags is a u16 at 106, and bit 1 is
  # VolumeDirty (bit 0 is ActiveFat, which says nothing about cleanliness).
  @exfat_volume_flags_offset 106
  @exfat_volume_dirty 0x0002

  # FAT[1]'s top bit(s) are the "clean shutdown" marker, and they are set
  # while the volume is clean — so a **cleared** bit is the dirty state.
  # FAT32 uses bit 27 of the 32-bit entry, FAT16 bit 15 of the 16-bit one.
  @fat32_clean_shut 0x08000000
  @fat16_clean_shut 0x8000

  # Everything up to and including BPB_FATSz32 (offset 36, 4 bytes wide).
  @bpb_bytes 40

  # The cluster-count thresholds are the FAT spec's own type determination
  # — nothing else distinguishes the three. FAT12 has no clean-shutdown
  # bit at all, and its 12-bit FAT[1] straddles a byte boundary, so
  # reading it as a u16 would invent a dirty flag out of FAT[2]'s bits.
  @fat12_max_clusters 4085
  @fat16_max_clusters 65_525

  @doc """
  Whether the filesystem records that it was **not** unmounted cleanly.

  `:unknown` means the answer is not in `head`: for vfat it is in FAT[1],
  so ask `dirty_probe/1` which bytes to read next and finish with
  `dirty_at?/3`. Pure — `head` is the same first 4 KiB `fs_type/1` reads.
  """
  @spec dirty?(fs_type() | nil, binary()) :: dirty()
  def dirty?(fs_type, head)

  def dirty?(:exfat, head) when is_binary(head) do
    if byte_size(head) >= @exfat_volume_flags_offset + 2 do
      <<flags::little-16>> = binary_part(head, @exfat_volume_flags_offset, 2)
      band(flags, @exfat_volume_dirty) != 0
    else
      :unknown
    end
  end

  # The dirty bit lives in FAT[1], which the reserved sectors put outside
  # the head on any FAT32 volume — a second read is unavoidable.
  def dirty?(:vfat, head) when is_binary(head), do: :unknown

  # fsck.ext4 -p runs before every ext4 mount (Storage.Mount), so the
  # superblock's own state is stale by the time anything could render it.
  def dirty?(:ext4, head) when is_binary(head), do: false

  # A dirty NTFS volume is mounted read-only by the kernel, and the
  # read-only mode is already reported.
  def dirty?(:ntfs3, head) when is_binary(head), do: false

  def dirty?(_fs_type, head) when is_binary(head), do: :unknown

  @doc """
  The extra bytes needed to answer `dirty?/2` for the volume `head` came
  from, as `{:read, offset, length}`, or `nil` when `head` alone settles
  it (or nothing ever will).

  The filesystem type and the offset both come out of `head`, so the
  caller only has to own the read.
  """
  @spec dirty_probe(binary()) :: {:read, non_neg_integer(), pos_integer()} | nil
  def dirty_probe(head) when is_binary(head) do
    with :vfat <- fs_type(head),
         {:ok, offset, length} <- fat_dirty_offset(head) do
      {:read, offset, length}
    else
      _other -> nil
    end
  end

  @doc """
  Finish a `dirty_probe/1` round trip: `bytes` are what the caller read at
  the offset the probe named, `head` is the same head the probe was
  derived from. Pure, and `:unknown` for anything that does not line up.
  """
  @spec dirty_at?(fs_type() | nil, binary(), binary()) :: dirty()
  def dirty_at?(:vfat, head, bytes) when is_binary(head) and is_binary(bytes) do
    case fat_dirty_offset(head) do
      {:ok, _offset, length} when byte_size(bytes) >= length -> fat_dirty?(bytes, length)
      _other -> :unknown
    end
  end

  def dirty_at?(fs_type, head, bytes) when is_binary(head) and is_binary(bytes),
    do: dirty?(fs_type, head)

  @doc """
  Where FAT[1]'s clean-shutdown flag sits on the volume `head` describes,
  as `{:ok, byte_offset, length}` (length 4 for FAT32, 2 for FAT16).

  `:error` for an unparsable BPB and for FAT12, which has no such flag.
  """
  @spec fat_dirty_offset(binary()) :: {:ok, non_neg_integer(), 2 | 4} | :error
  def fat_dirty_offset(head) when is_binary(head) do
    with {:ok, bpb} <- parse_bpb(head) do
      fat_start = bpb.reserved_sectors * bpb.bytes_per_sector

      # FAT[1] is the second entry of the first FAT, so its offset is one
      # entry width past the FAT's start.
      case fat_kind(bpb) do
        :fat32 -> {:ok, fat_start + 4, 4}
        :fat16 -> {:ok, fat_start + 2, 2}
        :fat12 -> :error
      end
    end
  end

  defp fat_dirty?(bytes, 4) do
    <<entry::little-32>> = binary_part(bytes, 0, 4)
    band(entry, @fat32_clean_shut) == 0
  end

  defp fat_dirty?(bytes, 2) do
    <<entry::little-16>> = binary_part(bytes, 0, 2)
    band(entry, @fat16_clean_shut) == 0
  end

  defp parse_bpb(head) when byte_size(head) >= @bpb_bytes do
    <<_jump_and_oem::binary-size(11), bytes_per_sector::little-16, sectors_per_cluster::8,
      reserved_sectors::little-16, num_fats::8, root_entries::little-16,
      total_sectors_16::little-16, _media::8, fat_size_16::little-16, _geometry::binary-size(8),
      total_sectors_32::little-32, fat_size_32::little-32, _rest::binary>> = head

    # A FAT32 BPB zeroes the 16-bit FAT-size and total-sector fields and
    # uses the 32-bit ones; a FAT16 BPB may use either total-sector field.
    bpb = %{
      bytes_per_sector: bytes_per_sector,
      sectors_per_cluster: sectors_per_cluster,
      reserved_sectors: reserved_sectors,
      num_fats: num_fats,
      root_entries: root_entries,
      fat_size: if(fat_size_16 != 0, do: fat_size_16, else: fat_size_32),
      total_sectors: if(total_sectors_16 != 0, do: total_sectors_16, else: total_sectors_32)
    }

    if plausible_bpb?(bpb), do: {:ok, bpb}, else: :error
  end

  defp parse_bpb(_head), do: :error

  defp plausible_bpb?(bpb) do
    bpb.bytes_per_sector in [512, 1024, 2048, 4096] and
      bpb.sectors_per_cluster > 0 and bpb.reserved_sectors > 0 and
      bpb.num_fats > 0 and bpb.fat_size > 0 and bpb.total_sectors > 0
  end

  defp fat_kind(bpb) do
    # The root directory is a fixed region on FAT12/16 and part of the data
    # region on FAT32, where `root_entries` is zero and this comes to zero
    # sectors too.
    root_dir_sectors =
      div(bpb.root_entries * 32 + bpb.bytes_per_sector - 1, bpb.bytes_per_sector)

    data_sectors =
      bpb.total_sectors -
        (bpb.reserved_sectors + bpb.num_fats * bpb.fat_size + root_dir_sectors)

    clusters = if data_sectors > 0, do: div(data_sectors, bpb.sectors_per_cluster), else: 0

    cond do
      clusters < @fat12_max_clusters -> :fat12
      clusters < @fat16_max_clusters -> :fat16
      true -> :fat32
    end
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
