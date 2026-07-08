defmodule UniversalProxy.Hardware do
  @moduledoc """
  Aggregates real hardware data for the Overview UI.

  Combines four sources:

    * `Circuits.UART.enumerate/0` — vendor / product / serial info per
      tty device (skipping the SoC's built-in UARTs)
    * `/sys/class/tty/<name>` symlinks — the stable USB bus path for
      each tty (`1-1.3`, `1-1.1.2`, etc.). This is the Nerves-friendly
      replacement for udev's `/dev/serial/by-path/`, which Nerves
      systems strip out.
    * `UniversalProxy.UART.Store` — persisted manual port-type configs
    * The compile-time `Mix.target/0` — a per-target list of physical
      USB-A connector bus paths (`@external_slots`). When the target
      is in that map every physical port renders as a row, populated
      or empty. Other targets fall back to dynamic enumeration of
      whatever's currently plugged in.

  Returns ports in a fixed shape consumed by the Overview LiveView.
  """

  alias UniversalProxy.UART
  alias UniversalProxy.UART.Enumerate

  @tty_class_dir "/sys/class/tty"

  # Per-target map of physical USB-A slot paths in numbered order. Each
  # entry says "this Nerves target has these external USB connectors;
  # render one row per slot regardless of plug state". If a target isn't
  # in this map we fall through to dynamic enumeration (only currently-
  # connected adapters show up).
  #
  # Pi 3 Model B+ has 4 external USB-A ports — two off each hub level.
  # The LAN7515's main hub provides `1-1.2` and `1-1.3`; the internal
  # SMSC2514 sub-hub provides `1-1.1.2` and `1-1.1.3`. The other empty
  # leaf in the topology (`1-1.4`) is advertised by the hub controller
  # but not wired to a physical connector.
  #
  # INVARIANT: no slot path may be a prefix of another (a device behind a hub
  # enumerates as `<slot>.<n>`, and consumers map it back to its slot by a
  # `<slot>.`-prefix match — so e.g. listing both `1-1.1` and `1-1.1.2` would
  # make the former wrongly claim the latter's devices).
  @external_slots %{
    rpi3: ["1-1.1.2", "1-1.1.3", "1-1.2", "1-1.3"]
  }

  # Captured at compile time so it works in releases without :mix.
  @target Mix.target()

  # ─── Single source of truth for USB device identification ──────────
  #
  # Each entry: `{vendor_id, product_id, %{...}}` where the map carries:
  #   * `:kind`      — port kind atom (`:ttl`, `:rs232`, `:rs485`,
  #                    `:zwave`, `:ir`)
  #   * `:name`      — adapter name shown in the table
  #   * `:vendor`    — overrides USB descriptor manufacturer (optional)
  #   * `:chip`      — chipset shown in the detail drawer (optional)
  #   * `:locked`    — true for branded devices whose kind is fixed by
  #                    hardware (ZWA-2, IR transceivers); false/omitted
  #                    for generic USB-serial chipsets where the kind is
  #                    a default the user can override per-port.
  #
  # **Add new entries here.** Branded products go in the first group;
  # generic chipsets (which default to TTL since most USB-serial cables
  # in the wild are TTL) go in the second.
  @usb_devices [
    # ── Branded products (kind locked by hardware) ────────────────
    # VID/PID from Home Assistant's zwave_js manifest (vid 303A =
    # Espressif — the ZWA-2's USB interface is its ESP32 bridge; the
    # Z-Wave radio itself is the EFR32ZG23).
    {0x303A, 0x4001,
     %{
       kind: :zwave,
       name: "Home Assistant Connect ZWA-2",
       vendor: "Nabu Casa",
       chip: "Silicon Labs EFR32ZG23",
       locked: true
     }},
    {0x04D8, 0xFD08,
     %{
       kind: :ir,
       name: "IRdroid IR Toy",
       vendor: "IRdroid",
       chip: "PIC18F2550",
       locked: true
     }},
    {0x04D8, 0xF58B,
     %{
       kind: :ir,
       name: "USB Infrared Transceiver",
       vendor: "Hardware Group",
       locked: true
     }},
    # FlooGoo FMA120 USB Bluetooth-audio dongle. The audio half enumerates
    # as a snd-usb-audio card; the control channel is FlooCast ASCII-over-
    # serial on its CDC-ACM node (`ttyACM*`). Locked so the ESPHome
    # `UART.Server` proxy never auto-opens the port — `FMA120.DeviceWorker`
    # is its sole owner.
    {0x0A12, 0x4007,
     %{
       kind: :bt_audio,
       name: "FlooGoo FMA120",
       vendor: "Flairmesh Technologies",
       chip: "Qualcomm/CSR",
       locked: true
     }},

    # ── Generic USB-to-serial chipsets (kind is editable) ─────────
    # The same chip is sold in both TTL pigtails and DB9 RS-232 cables;
    # the level shifter sits on the cable PCB, outside the USB
    # descriptor. We default each chip to its dominant retail variant
    # and let the user override per-port via the type select.
    #
    # Modern maker-board chips (FTDI FT232R/FT2232H/FT232H/FT231X,
    # SiLabs CP2102/CP2105, WCH CH340/CH9102) are overwhelmingly sold
    # as TTL pigtails / breakouts for Arduino/ESP/STM32 programming.
    # The Prolific PL2303 is the classic USB-to-DB9 RS-232 cable chip
    # — it predates the maker-board era and is still mostly seen on
    # legacy serial-console cables (Plugable, Sabrent, etc.).
    {0x0403, 0x6001, %{kind: :ttl, name: "USB Serial Adapter", chip: "FT232RL"}},
    {0x0403, 0x6010, %{kind: :ttl, name: "USB Serial Adapter", chip: "FT2232H"}},
    {0x0403, 0x6014, %{kind: :ttl, name: "USB Serial Adapter", chip: "FT232H"}},
    {0x0403, 0x6015, %{kind: :ttl, name: "USB Serial Adapter", chip: "FT231X"}},
    # NOTE: SONOFF Z-Wave 800 dongles also enumerate as 10C4:EA60 — HA
    # disambiguates by USB descriptor strings; here they take the manual
    # `:zwave` type selection, which `resolve_zwave_port/0` honors.
    {0x10C4, 0xEA60, %{kind: :ttl, name: "USB Serial Adapter", chip: "CP2102/CP2102N"}},
    {0x10C4, 0xEA70, %{kind: :ttl, name: "USB Serial Adapter", chip: "CP2105"}},
    {0x1A86, 0x7523, %{kind: :ttl, name: "USB Serial Adapter", chip: "CH340"}},
    {0x1A86, 0x55D4, %{kind: :ttl, name: "USB Serial Adapter", chip: "CH9102"}},
    {0x067B, 0x2303, %{kind: :rs232, name: "USB Serial Adapter", chip: "PL2303"}}
  ]

  @usb_device_table Map.new(@usb_devices, fn {vid, pid, info} -> {{vid, pid}, info} end)

  @kind_labels %{
    ttl: "TTL",
    rs232: "RS-232",
    rs485: "RS-485",
    zwave: "Z-Wave",
    ir: "IR",
    infrared: "IR",
    bt_audio: "BT Audio"
  }

  @doc "List of all VID/PID entries the module recognises (for introspection)."
  def known_devices, do: @usb_devices

  @doc """
  Enumerate physical USB-A ports with full display metadata.

  When the running target has a known external-slot mapping, returns
  one row per physical port (populated or empty). Otherwise returns
  one row per currently-connected USB serial adapter.

  ## Options

    * `:enumerated` — pre-built `Circuits.UART.enumerate/0` map
    * `:bus_paths` — pre-built `%{tty_name => bus_path}` map (skips
      sysfs probing)
    * `:tty_class_dir` — directory holding sysfs tty symlinks
      (default: `"/sys/class/tty"`)
    * `:slots` — explicit list of slot bus paths (overrides the
      target-based mapping; pass `nil` for dynamic mode)
    * `:saved_configs` — pre-built `%{serial_number => config}` map
    * `:in_use_ports` — pre-built `MapSet` of currently-opened tty
      basenames
    * `:zwave_claim` — the Z-Wave proxy's port claim
      (`%{tty_name: ..., subscribed: ...}` or `nil`); the proxy opens
      its tty directly rather than through `UART.Server`, so it never
      appears in `:in_use_ports`

  All defaults are wired to live system sources; tests inject fixtures.
  """
  @spec list_ports(keyword()) :: [map()]
  def list_ports(opts \\ []) do
    enumerated = Keyword.get_lazy(opts, :enumerated, &Enumerate.safe/0)
    bus_paths = Keyword.get_lazy(opts, :bus_paths, fn -> bus_paths_from_sysfs(opts) end)

    saved =
      Keyword.get_lazy(opts, :saved_configs, fn ->
        UART.saved_configs()
        |> Map.new(fn cfg ->
          {{cfg[:slot_sub], cfg[:vendor_id], cfg[:product_id]}, cfg}
        end)
      end)

    usage = %{
      in_use_ports:
        Keyword.get_lazy(opts, :in_use_ports, fn ->
          MapSet.new(UART.ports(), fn {name, _cfg} -> name end)
        end),
      zwave_claim:
        Keyword.get_lazy(opts, :zwave_claim, fn ->
          UniversalProxy.ESPHome.ZWaveProxy.claimed_port()
        end)
    }

    slots = Keyword.get(opts, :slots, target_slots())

    case slots do
      nil -> dynamic_listing(enumerated, bus_paths, saved, usage)
      slots -> slot_listing(slots, enumerated, bus_paths, saved, usage)
    end
  end

  @doc """
  Map of `{slot_sub, vendor_id, product_id} => tty_basename` for every
  currently-connected USB serial adapter. ESPHome consumers use this to
  resolve saved configs (which key by the same composite) to live
  device paths without each one re-walking sysfs.
  """
  @spec live_port_keys(keyword()) :: %{
          {String.t(), non_neg_integer() | nil, non_neg_integer() | nil} => String.t()
        }
  def live_port_keys(opts \\ []) do
    enumerated = Keyword.get_lazy(opts, :enumerated, &Enumerate.safe/0)
    bus_paths = Keyword.get_lazy(opts, :bus_paths, fn -> bus_paths_from_sysfs(opts) end)

    enumerated
    |> Enum.filter(fn {name, _} -> usb_serial?(name) end)
    |> Enum.flat_map(fn {tty_name, info} ->
      case Map.get(bus_paths, tty_name) do
        nil ->
          []

        slot_sub ->
          [{{slot_sub, info[:vendor_id], info[:product_id]}, tty_name}]
      end
    end)
    |> Map.new()
  end

  @usb_devices_dir "/sys/bus/usb/devices"
  # A device-level USB path under /sys/bus/usb/devices (e.g. "1-1.1.3"),
  # as opposed to a root hub ("usb1") or an interface ("1-1.3:1.0").
  @usb_device_path ~r/^\d+-[\d.]+$/

  @doc """
  Map of `bus_path => hub_info` for every USB **hub** currently enumerated
  under `/sys/bus/usb/devices` (devices whose `bDeviceClass` is `"09"`).

  A hub sits at the bus path of the receptacle it's plugged into, with the
  devices behind it enumerating one level deeper (`<hub_path>.<n>`). The
  Overview uses this to render a hub at its physical USB slot and indent the
  devices behind it as a tree — e.g. the FlooGoo FMA120 contains its own hub
  (`0a12:4010`), so it plugs into one receptacle but its functions enumerate
  at `<slot>.1`. Root hubs (`usbN`) are skipped.

  `hub_info` is `%{vendor_id, product_id, name}`.

  ## Options

    * `:usb_devices_dir` — sysfs root (default `"/sys/bus/usb/devices"`)
  """
  @spec usb_hubs(keyword()) :: %{
          String.t() => %{
            vendor_id: non_neg_integer() | nil,
            product_id: non_neg_integer() | nil,
            name: String.t()
          }
        }
  def usb_hubs(opts \\ []) do
    dir = Keyword.get(opts, :usb_devices_dir, @usb_devices_dir)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&Regex.match?(@usb_device_path, &1))
        |> Enum.flat_map(fn name ->
          base = Path.join(dir, name)

          if read_sysfs_attr(base, "bDeviceClass") == "09" do
            vid = parse_hex_id(read_sysfs_attr(base, "idVendor"))
            pid = parse_hex_id(read_sysfs_attr(base, "idProduct"))

            [
              {name,
               %{
                 vendor_id: vid,
                 product_id: pid,
                 name:
                   hub_name(
                     read_sysfs_attr(base, "product"),
                     read_sysfs_attr(base, "manufacturer"),
                     vid,
                     pid
                   )
               }}
            ]
          else
            []
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp read_sysfs_attr(base, file) do
    case File.read(Path.join(base, file)) do
      {:ok, value} -> String.trim(value)
      _ -> nil
    end
  end

  defp parse_hex_id(nil), do: nil

  defp parse_hex_id(str) do
    case Integer.parse(str, 16) do
      {n, _} -> n
      _ -> nil
    end
  end

  # Prefer a USB product string; fall back to a known device-table name, then
  # manufacturer, then a generic label. Many cheap hubs report no product.
  defp hub_name(product, manufacturer, vid, pid) do
    table_name = (Map.get(@usb_device_table, {vid, pid}) || %{})[:name]

    cond do
      is_binary(product) and product != "" -> product
      is_binary(table_name) -> table_name
      is_binary(manufacturer) and manufacturer != "" -> "#{manufacturer} USB hub"
      true -> "USB hub"
    end
  end

  @doc """
  Declared physical USB-A slot bus paths for the running target, in order, or
  `nil` when the target has no slot map (dynamic enumeration). Consumers use
  this to map any USB device's bus path back to the receptacle it occupies.
  """
  @spec physical_slots() :: [String.t()] | nil
  def physical_slots, do: target_slots()

  # `@target` is a compile-time literal; on :host it's not a key in
  # `@external_slots` (host has no static slots — the caller's `nil ->` branch
  # then falls back to dynamic listing). Route through `Map.new/1` so the type
  # checker treats this as an open `map()` lookup rather than proving the
  # literal map lacks the `:host` key (which trips --warnings-as-errors).
  defp target_slots, do: @external_slots |> Map.new() |> Map.get(@target)

  # -- Slot mode (per-target, every port shows) ------------------------

  defp slot_listing(slots, enumerated, bus_paths, saved, usage) do
    tty_by_bus_path = Map.new(bus_paths, fn {tty, bus} -> {bus, tty} end)
    known_slots = MapSet.new(slots)

    declared =
      slots
      |> Enum.with_index(1)
      |> Enum.map(fn {slot_sub, idx} ->
        case Map.get(tty_by_bus_path, slot_sub) do
          nil ->
            empty_port(slot_sub, idx)

          tty_name ->
            info = Map.get(enumerated, tty_name, %{})
            build_port(tty_name, info, slot_sub, saved, usage, idx)
        end
      end)

    # Surface anything plugged in that didn't match a known slot — it
    # likely means our slot table is wrong. Better to show it than hide
    # it.
    bonus =
      bus_paths
      |> Enum.reject(fn {_tty, bus_path} -> MapSet.member?(known_slots, bus_path) end)
      |> Enum.with_index(length(slots) + 1)
      |> Enum.map(fn {{tty_name, bus_path}, idx} ->
        info = Map.get(enumerated, tty_name, %{})
        build_port(tty_name, info, bus_path, saved, usage, idx)
      end)

    declared ++ bonus
  end

  # -- Dynamic mode (host / unknown target) ----------------------------

  defp dynamic_listing(enumerated, bus_paths, saved, usage) do
    enumerated
    |> Enum.filter(fn {name, _} -> usb_serial?(name) end)
    |> Enum.map(fn {name, info} -> {name, info, Map.get(bus_paths, name)} end)
    |> Enum.sort_by(fn {name, _info, bus_path} -> {bus_path || "~", name} end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{name, info, bus_path}, idx} ->
      slot_sub = bus_path || name
      build_port(name, info, slot_sub, saved, usage, idx)
    end)
  end

  # -- Sysfs-based bus path discovery ----------------------------------

  # Walks /sys/class/tty/<ttyUSB*|ttyACM*> symlinks. The link target
  # embeds the full USB device path under /sys/bus/usb/devices, e.g.
  #
  #   ../../devices/platform/soc/3f980000.usb/usb1/1-1/1-1.3/1-1.3:1.0/ttyUSB0/tty/ttyUSB0
  #
  # The interface segment `1-1.3:1.0` carries the bus path before the
  # colon — that's the stable identifier of the physical USB receptacle.
  defp bus_paths_from_sysfs(opts) do
    dir = Keyword.get(opts, :tty_class_dir, @tty_class_dir)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&usb_serial?/1)
        |> Enum.flat_map(fn name ->
          case File.read_link(Path.join(dir, name)) do
            {:ok, target} ->
              case parse_bus_path(target) do
                nil -> []
                bus_path -> [{name, bus_path}]
              end

            _ ->
              []
          end
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  @bus_path_segment ~r/^(\d+-[\d.]+):\d+\.\d+$/

  defp parse_bus_path(symlink) do
    symlink
    |> String.split("/")
    |> Enum.find_value(fn segment ->
      case Regex.run(@bus_path_segment, segment) do
        [_, bus_path] -> bus_path
        _ -> nil
      end
    end)
  end

  # Built-in SoC UARTs (ttyAMA*, ttyS*) and console ports are not USB
  # and have no bus path; we don't surface them in the table.
  defp usb_serial?(name), do: String.starts_with?(name, ["ttyUSB", "ttyACM"])

  # -- Port shape ------------------------------------------------------

  defp build_port(tty_name, info, slot_sub, saved, usage, idx) do
    vid = info[:vendor_id]
    pid = info[:product_id]
    serial = info[:serial_number]
    {in_use?, user} = port_usage(tty_name, usage)
    device_info = Map.get(@usb_device_table, {vid, pid})
    saved_cfg = Map.get(saved, {slot_sub, vid, pid})

    classification = classify(device_info, saved_cfg)
    name = pick_name(saved_cfg, device_info, info)
    vendor = pick_vendor(device_info, info)
    chip = pick_chip(device_info, info)

    %{
      id: port_id(slot_sub),
      slot: "USB #{idx}",
      slot_sub: slot_sub,
      detection: classification.detection,
      name: name,
      vendor: vendor,
      kind: classification.kind,
      kind_label: classification.kind_label,
      device: "/dev/" <> tty_name,
      tty_name: tty_name,
      chip: chip,
      serial: serial || "—",
      vendor_id: vid,
      product_id: pid,
      vidpid: format_vidpid(vid, pid),
      ha_name: ha_picker_name(name, vendor, chip, slot_sub),
      connected: true,
      in_use: in_use?,
      configured: classification.configured,
      locked: classification.locked,
      user: user,
      user_href: nil,
      baud: nil,
      throughput: %{in: 0, out: 0, unit: "B/s"},
      errors: 0,
      since: nil,
      notes: classification.notes
    }
  end

  # Who holds this tty open, if anyone. The Z-Wave proxy owns its port
  # directly (never via UART.Server), so it gets its own label; the
  # subscribed flag distinguishes an attached Z-Wave JS client from the
  # proxy merely holding the port open.
  defp port_usage(tty_name, %{zwave_claim: %{tty_name: tty_name} = claim}) do
    {true, if(claim.subscribed, do: "Z-Wave JS · Home Assistant", else: "Z-Wave proxy")}
  end

  defp port_usage(tty_name, %{in_use_ports: in_use_ports}) do
    if MapSet.member?(in_use_ports, tty_name) do
      {true, "ESPHome serial proxy"}
    else
      {false, nil}
    end
  end

  # Format a port for display in Home Assistant's serial port picker.
  # Branded products (specific `name` string from the device table) are
  # shown as-is; generic "USB Serial Adapter" entries collapse to
  # vendor + chip ("FTDI FT232RL") so the user sees something they can
  # recognise on the cable.
  defp ha_picker_name(name, vendor, chip, slot_sub) do
    generic? = is_nil(name) or name =~ ~r/usb\s*serial/i

    base =
      if generic? do
        [vendor, chip]
        |> Enum.reject(&blank_or_dash?/1)
        |> Enum.join(" ")
      else
        name
      end

    base = if base in [nil, ""], do: "USB serial", else: base
    "#{base} (#{slot_sub})"
  end

  defp blank_or_dash?(nil), do: true
  defp blank_or_dash?(""), do: true
  defp blank_or_dash?("—"), do: true
  defp blank_or_dash?(_), do: false

  defp pick_name(saved_cfg, device_info, info) do
    user_friendly_name(saved_cfg) ||
      (device_info && device_info[:name]) ||
      info[:description] ||
      "USB Serial Adapter"
  end

  # Defends against legacy DETS records: an earlier revision of
  # `UniversalProxy.UART.Store` auto-filled `friendly_name` with the
  # placeholder `"tty<serial>"` when the caller didn't supply one. The
  # current Store leaves `friendly_name` absent in that case, but
  # `prune_legacy_records/1` only drops entries with non-tuple keys, so
  # a tuple-keyed record carrying that legacy placeholder can survive
  # across the migration. Treat the placeholder as "no name set" so the
  # device-table name (e.g. "USB Serial Adapter") wins.
  defp user_friendly_name(nil), do: nil

  defp user_friendly_name(saved_cfg) do
    case {saved_cfg[:friendly_name], saved_cfg[:serial_number]} do
      {nil, _} -> nil
      {"", _} -> nil
      {name, serial} when is_binary(serial) and name == "tty" <> serial -> nil
      {name, _} -> name
    end
  end

  defp pick_vendor(device_info, info) do
    (device_info && device_info[:vendor]) || info[:manufacturer] || "—"
  end

  defp pick_chip(device_info, info) do
    (device_info && device_info[:chip]) || info[:description] || "—"
  end

  defp empty_port(slot_sub, idx) do
    %{
      id: port_id(slot_sub),
      slot: "USB #{idx}",
      slot_sub: slot_sub,
      detection: nil,
      name: nil,
      vendor: nil,
      kind: nil,
      kind_label: nil,
      device: nil,
      tty_name: nil,
      chip: nil,
      serial: nil,
      vendor_id: nil,
      product_id: nil,
      vidpid: nil,
      ha_name: nil,
      connected: false,
      in_use: false,
      configured: false,
      locked: false,
      user: nil,
      user_href: nil,
      baud: nil,
      throughput: %{in: 0, out: 0, unit: "B/s"},
      errors: 0,
      since: nil,
      notes: nil
    }
  end

  # Branded device: hardware-locked, ignore any saved override.
  defp classify(%{locked: true, kind: kind}, _saved) do
    %{
      kind: kind,
      kind_label: Map.get(@kind_labels, kind, to_string(kind)),
      detection: :auto,
      configured: true,
      locked: true,
      notes: nil
    }
  end

  # User saved a per-port config — wins over the chipset default.
  defp classify(_device_info, %{port_type: kind}) do
    %{
      kind: kind,
      kind_label: Map.get(@kind_labels, kind, to_string(kind)),
      detection: :manual,
      configured: true,
      locked: false,
      notes: nil
    }
  end

  # Generic chipset default (TTL for FT232R/CH340/CP2105/PL2303/etc).
  defp classify(%{kind: kind}, nil) do
    %{
      kind: kind,
      kind_label: Map.get(@kind_labels, kind, to_string(kind)),
      detection: :auto,
      configured: true,
      locked: false,
      notes: nil
    }
  end

  # Unknown VID/PID with no saved config.
  defp classify(nil, nil) do
    %{
      kind: nil,
      kind_label: "Generic USB serial",
      detection: :unknown,
      configured: false,
      locked: false,
      notes: "Pick a port type to expose this adapter."
    }
  end

  # -- Helpers ---------------------------------------------------------

  # Stable, HTML-safe id derived from the slot path. Survives
  # plug/unplug events on the same physical port.
  defp port_id(slot_sub) do
    "p_" <> String.replace(slot_sub, ~r/[^a-zA-Z0-9]+/, "_")
  end

  defp format_vidpid(vid, pid) when is_integer(vid) and is_integer(pid) do
    vid_hex = vid |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0")
    pid_hex = pid |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(4, "0")
    vid_hex <> ":" <> pid_hex
  end

  defp format_vidpid(_, _), do: "—"
end
