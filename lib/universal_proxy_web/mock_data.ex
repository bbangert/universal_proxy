defmodule UniversalProxyWeb.MockData do
  @moduledoc """
  Static fixtures used by the new UI to render the Hassever design.

  These mirror the mock data in the design handoff bundle. Real data
  sources (Nerves system info, traffic decoders, encryption key store,
  health stats) will replace these incrementally — for now the UI is
  visual-only against fixtures so the design renders end-to-end.
  """

  @ports [
    %{
      id: "p1",
      slot: "USB 1",
      slot_sub: "1-1.1",
      detection: :auto,
      name: "Home Assistant Connect ZWA-2",
      vendor: "Nabu Casa",
      kind: :zwave,
      kind_label: "Z-Wave",
      device: "/dev/ttyACM0",
      chip: "Silicon Labs EFR32ZG23",
      serial: "DH001K8R",
      vidpid: "10C4:EA60",
      connected: true,
      in_use: true,
      configured: true,
      user: "Z-Wave JS · Home Assistant",
      user_href: "http://homeassistant.local:8123/config/integrations",
      baud: 115_200,
      throughput: %{in: 218, out: 42, unit: "B/s"},
      errors: 0,
      since: "3d 14h",
      notes: "Local ACK/NAK · 48 nodes paired"
    },
    %{
      id: "p2",
      slot: "USB 2",
      slot_sub: "1-1.2",
      detection: :auto,
      name: "IRdroid IR Toy",
      vendor: "IRdroid",
      kind: :ir,
      kind_label: "Infrared",
      device: "/dev/ttyACM1",
      chip: "PIC18F2550",
      serial: "IRT-7B2A-9F",
      vidpid: "04D8:FD08",
      connected: true,
      in_use: true,
      configured: true,
      user: "ESPHome IR entity",
      user_href: "#",
      baud: nil,
      throughput: %{in: 0, out: 6, unit: "B/s"},
      errors: 0,
      since: "11h 02m",
      notes: "TX + RX supported"
    },
    %{
      id: "p3",
      slot: "USB 3",
      slot_sub: "1-1.3",
      detection: :manual,
      name: "USB Serial Adapter",
      vendor: "FTDI",
      kind: :rs485,
      kind_label: "RS-485",
      device: "/dev/ttyUSB0",
      chip: "FT232RL",
      serial: "FTAB5QZ1",
      vidpid: "0403:6001",
      connected: true,
      in_use: true,
      configured: true,
      user: "ESPHome serial proxy",
      user_href: "#",
      baud: 9600,
      parity: "none",
      stop_bits: 1,
      data_bits: 8,
      throughput: %{in: 84, out: 12, unit: "B/s"},
      errors: 0,
      since: "2d 06h",
      notes: "Configured as RS-485 by user"
    },
    %{
      id: "p4",
      slot: "USB 4",
      slot_sub: "1-1.4",
      detection: :unknown,
      name: "USB Serial Adapter",
      vendor: "QinHeng Electronics",
      kind: nil,
      kind_label: "Generic USB serial",
      device: "/dev/ttyUSB1",
      chip: "CH340",
      serial: "CH340-7735-B1",
      vidpid: "1A86:7523",
      connected: true,
      in_use: false,
      configured: false,
      user: nil,
      user_href: nil,
      baud: nil,
      throughput: %{in: 0, out: 0, unit: "B/s"},
      errors: 0,
      since: "4m 11s",
      notes: "Plugged in just now — pick a port type to expose it."
    }
  ]

  @kind_meta %{
    zwave: %{tint: "#7c4dff", tint_class: "text-zwave", label: "Z-Wave"},
    zigbee: %{tint: "#00a388", tint_class: "text-success", label: "Zigbee"},
    ir: %{tint: "#f0a818", tint_class: "text-ir", label: "IR"},
    rs232: %{tint: "#e5484d", tint_class: "text-rs232", label: "RS-232"},
    rs485: %{tint: "#03a9f4", tint_class: "text-rs485", label: "RS-485"},
    ttl: %{tint: "#2fb866", tint_class: "text-ttl", label: "TTL"},
    unknown: %{tint: "var(--hs-fg-3)", tint_class: "text-fg-3", label: "Unconfigured"}
  }

  @clients [
    %{
      id: "ha",
      name: "Home Assistant",
      kind: "Home Assistant Core",
      version: "2026.4.2",
      host: "homeassistant.local",
      ip: "10.0.1.20",
      since: "3d 14h",
      last_packet: "12s ago",
      auth_user: "long_lived_token · ha-core",
      subscriptions: ["p1", "p2", "p3"]
    },
    %{
      id: "dash",
      name: "ESPHome dashboard",
      kind: "ESPHome web UI",
      version: "2026.4.0",
      host: "esphome.local",
      ip: "10.0.1.55",
      since: "8m 41s",
      last_packet: "2s ago",
      auth_user: "viewer (read-only)",
      subscriptions: ["p3"]
    }
  ]

  @sys_log [
    {"2026-04-19 10:32:14", "INFO", "hassever-proxy 2026.4.1 starting up"},
    {"2026-04-19 10:32:14", "INFO", "loaded config from /etc/hassever/proxy.yaml"},
    {"2026-04-19 10:32:15", "INFO", "probing USB bus — 3 devices enumerated"},
    {"2026-04-19 10:32:15", "INFO", "ttyACM0 → Silicon Labs EFR32ZG23 (Z-Wave)"},
    {"2026-04-19 10:32:15", "INFO", "ttyUSB0 → FLIRC v2"},
    {"2026-04-19 10:32:15", "INFO", "ttyUSB1 → FTDI FT232RL @ 9600 8N1"},
    {"2026-04-19 10:32:15", "WARN", "PORT 3 enumeration failed — no device present"},
    {"2026-04-19 10:32:16", "INFO", "mDNS advertising universal-proxy-a1.local"},
    {"2026-04-19 10:32:16", "INFO", "native API server listening on :6053 (TLS)"},
    {"2026-04-19 10:32:17", "INFO", "web UI listening on :443"},
    {"2026-04-19 10:32:24", "INFO", "client 10.0.1.20 authenticated (Home Assistant)"},
    {"2026-04-19 11:02:11", "INFO", "Z-Wave JS subscribed to SLOT A stream"},
    {"2026-04-19 13:47:02", "INFO", "FLIRC claimed by esphome-proxy broadlink bridge"},
    {"2026-04-19 14:08:33", "WARN", "PORT 2 claimed but no reads in 30 min"}
  ]

  @health %{
    uptime: "3 d 14 h",
    load_avg: "0.21",
    memory: "42 / 512 MB",
    cpu_temp: "46.2 °C",
    storage: "1.3 / 8 GB",
    network: "Ethernet, 1 Gbps"
  }

  @discovery_defaults %{
    friendly: "Universal Proxy (Rack)",
    hostname: "universal-proxy-a1.local",
    service: "_hassever-proxy._tcp",
    esphome_id: "universal_proxy_a1",
    area: "Server rack",
    advertise: true
  }

  @doc "Mock connected ports."
  def ports, do: @ports

  @doc "Look up a single port by id."
  def port(id), do: Enum.find(@ports, &(&1.id == id))

  @doc "Port-kind metadata (color tints + labels)."
  def kind_meta, do: @kind_meta
  def kind_meta(nil), do: @kind_meta.unknown
  def kind_meta(kind), do: Map.get(@kind_meta, kind, @kind_meta.unknown)

  @doc "Mock connected ESPHome native-API clients."
  def clients, do: @clients

  @doc "Mock system log lines (timestamp, level, message)."
  def sys_log, do: @sys_log

  @doc "Mock health stats."
  def health, do: @health

  @doc "Default discovery form values."
  def discovery_defaults, do: @discovery_defaults

  @doc "Compute the visual status badge for a port."
  def port_status(%{connected: false}), do: %{label: "Empty", variant: :neutral}
  def port_status(%{configured: false}), do: %{label: "Needs setup", variant: :warning}
  def port_status(%{in_use: true}), do: %{label: "Active", variant: :success}
  def port_status(_), do: %{label: "Idle", variant: :warning}

  @doc "Generate a fake but believable 32-byte API key in base64."
  def generate_api_key do
    32 |> :crypto.strong_rand_bytes() |> Base.encode64()
  end

  @doc "Seed a few sample traffic frames for the Traffic tab."
  def seed_traffic do
    Enum.map(0..17, &sample_frame(&1))
  end

  defp sample_frame(seq) do
    {port_id, dir, proto, summary, hex} = pick_template(seq)

    %{
      id: "seed-#{seq}",
      ts: timestamp(seq),
      port: port_id,
      dir: dir,
      proto: proto,
      summary: summary,
      hex: hex
    }
  end

  defp pick_template(seq) do
    templates = [
      {"p1", :rx, "Z-Wave", "SENSOR_MULTILEVEL report · Node 23 · temperature 21.4 °C", nil},
      {"p1", :tx, "Z-Wave", "SWITCH_BINARY set · Node 11 · value = ON", nil},
      {"p1", :rx, "Z-Wave", "METER report · Node 34 · 142.8 W", nil},
      {"p1", :rx, "Z-Wave", "BATTERY report · Node 19 · 74 %", nil},
      {"p2", :tx, "IR NEC", "samsung_tv · VOL_UP · addr 0x07 cmd 0x12", nil},
      {"p2", :tx, "IR NEC", "denon_avr · POWER_TOGGLE · addr 0x04 cmd 0x48", nil},
      {"p3", :rx, "Modbus", "slave 0x01 · FC 03 · read holding 40001..40010",
       "01 03 00 00 00 0A C5 CD"},
      {"p3", :rx, "Modbus", "slave 0x01 → master · 10 registers",
       "01 03 14 00 DC 00 06 00 00 ..."},
      {"p3", :tx, "Modbus", "slave 0x07 · FC 06 · write 40023 = 0x00F0",
       "07 06 00 16 00 F0 6B A9"}
    ]

    Enum.at(templates, rem(seq, length(templates)))
  end

  defp timestamp(offset) do
    now = DateTime.utc_now() |> DateTime.add(-offset, :second)
    Calendar.strftime(now, "%H:%M:%S") <> ".000"
  end
end
