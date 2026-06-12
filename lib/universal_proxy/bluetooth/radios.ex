defmodule UniversalProxy.Bluetooth.Radios do
  @moduledoc """
  Bluetooth adapter (radio) enumeration from sysfs.

  sysfs (`/sys/class/bluetooth/hci*/`) is the discovery source that works
  regardless of whether `bluetoothd` is running — the kernel creates these
  entries as soon as a controller binds, so the radio list (and MAC → hciX
  resolution) is available even while the BlueZ subtree is stopped or the
  daemon is still coming up. Live `org.bluez` properties (Name, Powered)
  are merged on top by `UniversalProxy.Bluetooth.RadioMonitor` when the
  daemon is up.

  Addresses are normalized to uppercase `AA:BB:CC:DD:EE:FF` — the same form
  `UniversalProxy.Bluetooth.Settings` persists, so resolution is a plain
  string compare. An all-zero address (controller not yet initialized by
  the kernel) reads back as `nil`.

  Chip name / BT version / BLE+BR-EDR capability badges come from a small
  static lookup over the device modalias (DT compatible strings for SoC
  radios, VID:PID for USB dongles) — best-effort with an "Unknown"
  fallback; there is no clean kernel API for these without the mgmt socket
  (which belongs to `bluetoothd`).

  The sysfs root is a parameter so host tests can point at a fixture tree.
  """

  @default_root "/sys/class/bluetooth"

  @type adapter :: %{hci: String.t(), address: String.t() | nil}

  @type radio :: %{
          hci: String.t(),
          address: String.t() | nil,
          bus: :uart | :usb | :unknown,
          detail: String.t(),
          chip: String.t(),
          bt_version: String.t() | nil,
          ble?: boolean(),
          bredr?: boolean()
        }

  # USB dongles by VID:PID. The ASUS USB-BT500 (the bench dongle) is an
  # RTL8761B behind ASUS's VID; 0BDA:8771 is the same chip under Realtek's.
  @usb_chips %{
    {0x0B05, 0x190E} => %{chip: "Realtek RTL8761B (ASUS USB-BT500)", bt_version: "5.0"},
    {0x0BDA, 0x8771} => %{chip: "Realtek RTL8761B", bt_version: "5.1"},
    {0x0BDA, 0x2550} => %{chip: "Realtek RTL8761BU", bt_version: "5.1"},
    {0x0A12, 0x0001} => %{chip: "CSR8510 A10", bt_version: "4.0"},
    {0x8087, 0x0029} => %{chip: "Intel AX200", bt_version: "5.2"},
    {0x8087, 0x0026} => %{chip: "Intel Wireless-AC 9260", bt_version: "5.1"}
  }

  # SoC radios by DT-compatible substring (from the `of:` modalias). Order
  # matters: more specific first ("bcm43455" would also substring-match a
  # hypothetical shorter key).
  @of_chips [
    {"bcm43455", %{chip: "Broadcom BCM4345C0 (CYW43455)", bt_version: "5.0"}},
    {"bcm4345c0", %{chip: "Broadcom BCM4345C0", bt_version: "5.0"}},
    {"bcm43438", %{chip: "Broadcom BCM43438 (CYW43438)", bt_version: "4.1"}}
  ]

  # All radios we can identify do both BLE and BR/EDR; the unknown fallback
  # claims the same (a Linux hci controller without BLE couldn't serve this
  # proxy at all).
  @chip_defaults %{ble?: true, bredr?: true}
  @unknown_chip Map.merge(%{chip: "Unknown", bt_version: nil}, @chip_defaults)

  @doc """
  List the controllers the kernel knows about, sorted by hci index.

  Returns `[]` when the sysfs class directory is missing (host, or a board
  with no controller bound yet).
  """
  @spec sysfs_adapters(Path.t()) :: [adapter()]
  def sysfs_adapters(root \\ @default_root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&Regex.match?(~r/^hci\d+$/, &1))
        |> Enum.sort_by(&hci_index/1)
        |> Enum.map(fn hci -> %{hci: hci, address: read_address(root, hci)} end)

      {:error, _} ->
        []
    end
  end

  @doc """
  Full enumeration: `sysfs_adapters/1` plus bus classification (UART SoC
  vs USB dongle, with the USB port and link speed) and the static chip
  lookup. Everything here is kernel-sourced — live BlueZ properties are
  merged elsewhere.
  """
  @spec enumerate(Path.t()) :: [radio()]
  def enumerate(root \\ @default_root) do
    for %{hci: hci, address: address} <- sysfs_adapters(root) do
      modalias = read_modalias(root, hci)
      {bus, detail, usb_id} = classify_bus(root, hci, modalias)

      %{hci: hci, address: address, bus: bus, detail: detail}
      |> Map.merge(chip_lookup(modalias, usb_id))
    end
  end

  @doc ~S|The numeric index of an `"hciX"` name (`"hci10"` → `10`).|
  @spec hci_index(String.t()) :: non_neg_integer()
  def hci_index("hci" <> index), do: String.to_integer(index)

  # ── sysfs reads ──────────────────────────────────────────────────────────

  defp read_address(root, hci) do
    case File.read(Path.join([root, hci, "address"])) do
      {:ok, raw} ->
        case raw |> String.trim() |> String.upcase() do
          # The kernel reports all-zeros until the controller is initialized.
          "00:00:00:00:00:00" -> nil
          "" -> nil
          address -> address
        end

      {:error, _} ->
        nil
    end
  end

  # The parent device's modalias identifies the transport and the chip:
  # `of:N...Cbrcm,bcm43438-bt` for DT/serdev radios, `usb:vXXXXpYYYY...`
  # for dongles. Fall back to the MODALIAS= line of uevent (some serdev
  # devices expose only that).
  defp read_modalias(root, hci) do
    device = Path.join([root, hci, "device"])

    case File.read(Path.join(device, "modalias")) do
      {:ok, raw} ->
        String.trim(raw)

      {:error, _} ->
        with {:ok, uevent} <- File.read(Path.join(device, "uevent")),
             [modalias] <-
               uevent
               |> String.split("\n")
               |> Enum.flat_map(fn
                 "MODALIAS=" <> rest -> [String.trim(rest)]
                 _ -> []
               end) do
          modalias
        else
          _ -> nil
        end
    end
  end

  # ── bus classification ───────────────────────────────────────────────────

  defp classify_bus(root, hci, modalias) do
    cond do
      usb_id = parse_usb_modalias(modalias) ->
        {:usb, usb_detail(root, hci), usb_id}

      is_binary(modalias) and String.starts_with?(modalias, "of:") ->
        {:uart, "SoC · UART", nil}

      is_binary(modalias) and String.starts_with?(modalias, "serial:") ->
        {:uart, "SoC · UART", nil}

      device_path_contains?(root, hci, "/usb") ->
        {:usb, usb_detail(root, hci), nil}

      device_path_contains?(root, hci, "serial") ->
        {:uart, "SoC · UART", nil}

      true ->
        {:unknown, "Unknown", nil}
    end
  end

  defp parse_usb_modalias(modalias) when is_binary(modalias) do
    case Regex.run(~r/^usb:v([0-9A-Fa-f]{4})p([0-9A-Fa-f]{4})/, modalias) do
      [_, vid, pid] -> {String.to_integer(vid, 16), String.to_integer(pid, 16)}
      nil -> nil
    end
  end

  defp parse_usb_modalias(_), do: nil

  # "USB 2.0 · port 1-1.2": port from the interface directory name in the
  # resolved device path (".../1-1.2/1-1.2:1.0"), USB version from the USB
  # device's `speed` attribute one level up.
  defp usb_detail(root, hci) do
    case resolved_device_path(root, hci) do
      nil ->
        "USB"

      real ->
        port = real |> Path.basename() |> String.split(":") |> hd()
        speed = read_speed(Path.dirname(real))
        "#{usb_generation(speed)} · port #{port}"
    end
  end

  defp read_speed(usb_device_dir) do
    case File.read(Path.join(usb_device_dir, "speed")) do
      {:ok, raw} -> String.trim(raw)
      {:error, _} -> nil
    end
  end

  defp usb_generation("1.5"), do: "USB 1.0"
  defp usb_generation("12"), do: "USB 1.1"
  defp usb_generation("480"), do: "USB 2.0"
  defp usb_generation("5000"), do: "USB 3.0"
  defp usb_generation("10000"), do: "USB 3.1"
  defp usb_generation(_), do: "USB"

  defp resolved_device_path(root, hci) do
    link = Path.join([root, hci, "device"])

    case File.read_link(link) do
      {:ok, target} -> Path.expand(target, Path.dirname(link))
      {:error, _} -> nil
    end
  end

  defp device_path_contains?(root, hci, fragment) do
    case resolved_device_path(root, hci) do
      nil -> false
      real -> String.contains?(real, fragment)
    end
  end

  # ── chip lookup ──────────────────────────────────────────────────────────

  defp chip_lookup(_modalias, usb_id) when usb_id != nil do
    case Map.fetch(@usb_chips, usb_id) do
      {:ok, entry} -> Map.merge(entry, @chip_defaults)
      :error -> @unknown_chip
    end
  end

  defp chip_lookup(modalias, nil) when is_binary(modalias) do
    Enum.find_value(@of_chips, @unknown_chip, fn {fragment, entry} ->
      if String.contains?(modalias, fragment), do: Map.merge(entry, @chip_defaults)
    end)
  end

  defp chip_lookup(_, _), do: @unknown_chip
end
