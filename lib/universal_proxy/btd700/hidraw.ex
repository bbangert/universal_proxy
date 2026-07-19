defmodule UniversalProxy.BTD700.Hidraw do
  @moduledoc """
  Control-node discovery for the BTD 700's HID transport.

  The dongle exposes (at least) two `hidraw*` nodes off the same USB
  device: a consumer-keys collection and the vendor control collection
  (usage page `0xFFA2`, numbered reports keyed by report ID `0x34`). Live
  probing (`research/hw-probe.md`) found the two collections can even
  share a single multi-collection hidraw node — so node selection must
  never assume an index or "the other vendor node"; it must parse each
  candidate's report descriptor.

  Discovery is two-stage:

    1. **Bus-path filter** — narrow to hidraw nodes whose `HID_PHYS` sysfs
       attribute resolves to the given USB bus path (e.g. `"1-1.3.1"`).
       This is a *prefix-safe* match on the port-path portion of `HID_PHYS`
       (never the trailing `/inputN` interface index — that index is not
       stable across the consumer/vendor collections and, per the live
       probe, doesn't even predict which node carries the control
       collection).
    2. **Descriptor content match** — among same-device candidates, pick
       the one whose `report_descriptor` contains both the usage-page-
       0xFFA2 marker (`<<0x06, 0xA2, 0xFF>>`) and the report-ID-0x34
       marker (`<<0x85, 0x34>>`).

  The sysfs root is injectable so tests can point at a tmp fixture tree
  instead of the real `/sys/class/hidraw`.
  """

  @hidraw_class_dir "/sys/class/hidraw"

  # Usage Page (Vendor, 0xFFA2) — `06 A2 FF` in the HID report descriptor.
  @usage_page_marker <<0x06, 0xA2, 0xFF>>
  # Report ID (0x34) — `85 34` in the HID report descriptor.
  @report_id_marker <<0x85, 0x34>>

  @doc """
  Find the `/dev/hidrawN` control node for the device at `usb_port` (a
  sysfs bus path like `"1-1.3.1"`).

  ## Options

    * `:hidraw_class_dir` — sysfs root (default `"/sys/class/hidraw"`)
  """
  @spec control_node(String.t(), keyword()) :: {:ok, String.t()} | {:error, :not_found}
  def control_node(usb_port, opts \\ []) when is_binary(usb_port) do
    dir = Keyword.get(opts, :hidraw_class_dir, @hidraw_class_dir)
    port_suffix = port_path_suffix(usb_port)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.starts_with?(&1, "hidraw"))
        |> Enum.sort_by(&hidraw_index/1)
        |> Enum.find(fn name ->
          base = Path.join(dir, name)
          matches_bus_path?(base, port_suffix) and matches_control_descriptor?(base)
        end)
        |> case do
          nil -> {:error, :not_found}
          name -> {:ok, "/dev/#{name}"}
        end

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  # `HID_PHYS` carries the port-path portion of the bus path with no bus
  # number (e.g. "usb-<controller>-1.3.1/input0" for sysfs id "1-1.3.1") —
  # strip the leading "<bus>-" so we compare like with like.
  defp port_path_suffix(usb_port) do
    case String.split(usb_port, "-", parts: 2) do
      [_bus, path] -> path
      [path] -> path
    end
  end

  defp matches_bus_path?(base, port_suffix) do
    case read_file(Path.join([base, "device", "uevent"])) do
      nil -> false
      content -> phys_matches_suffix?(content, port_suffix)
    end
  end

  # Anchors the match on "-<port_suffix>/input" so a shorter sibling port
  # path (e.g. "1.3") can never wrongly prefix-match a deeper one
  # (e.g. "1.3.1") — the same collision `Hardware`'s external-slot map
  # guards against for tty bus paths.
  defp phys_matches_suffix?(uevent_content, port_suffix) do
    case Regex.run(~r/^HID_PHYS=(.+)$/m, uevent_content) do
      [_, phys] -> String.contains?(phys, "-#{port_suffix}/input")
      nil -> false
    end
  end

  defp matches_control_descriptor?(base) do
    case read_file(Path.join([base, "device", "report_descriptor"])) do
      nil ->
        false

      descriptor ->
        contains?(descriptor, @usage_page_marker) and contains?(descriptor, @report_id_marker)
    end
  end

  defp contains?(binary, pattern) do
    :binary.match(binary, pattern) != :nomatch
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _reason} -> nil
    end
  end

  defp hidraw_index("hidraw" <> n) do
    case Integer.parse(n) do
      {i, _rest} -> i
      :error -> 0
    end
  end
end
