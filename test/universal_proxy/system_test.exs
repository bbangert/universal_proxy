defmodule UniversalProxy.SystemTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.System, as: Sys

  describe "firmware_info/1" do
    test "reads from injected KV map" do
      kv = %{
        "nerves_fw_version" => "1.2.3",
        "nerves_fw_platform" => "rpi3",
        "nerves_fw_uuid" => "abcdef12-1234-5678-9012-345678901234",
        "nerves_fw_validated" => "1",
        "nerves_fw_vcs_identifier" => "deadbeef",
        "nerves_fw_author" => "The Nerves Team",
        "nerves_fw_product" => "universal_proxy",
        "nerves_fw_architecture" => "arm"
      }

      info = Sys.firmware_info(kv: kv)

      assert info.version == "1.2.3"
      assert info.target == "rpi3"
      assert info.uuid == "abcdef12-1234-5678-9012-345678901234"
      assert info.validated == true
      assert info.vcs_identifier == "deadbeef"
      assert info.author == "The Nerves Team"
      assert info.product == "universal_proxy"
      assert info.architecture == "arm"
    end

    test "validated=false when KV value is not '1'" do
      info = Sys.firmware_info(kv: %{"nerves_fw_validated" => "0"})
      assert info.validated == false
    end

    test "blank vcs_identifier becomes nil" do
      info = Sys.firmware_info(kv: %{"nerves_fw_vcs_identifier" => ""})
      assert info.vcs_identifier == nil
    end

    test "falls back to application version when no KV version" do
      info = Sys.firmware_info(kv: %{})
      # Either the real app version or "—" — both acceptable on the host.
      assert is_binary(info.version)
    end
  end

  describe "parse_meminfo/1 + format_memory/1" do
    test "parses /proc/meminfo and computes used/total" do
      sample = """
      MemTotal:         831568 kB
      MemFree:          710708 kB
      MemAvailable:     754872 kB
      Buffers:           12340 kB
      """

      fields = Sys.parse_meminfo(sample)
      assert fields["MemTotal"] == 831_568
      assert fields["MemAvailable"] == 754_872
      # used = 831568 - 754872 = 76696 kB → 74 MB
      assert Sys.format_memory(fields) == "74 / 812 MB"
    end

    test "falls back to MemFree when MemAvailable is missing" do
      sample = "MemTotal: 1024 kB\nMemFree: 512 kB\n"
      fields = Sys.parse_meminfo(sample)
      assert Sys.format_memory(fields) == "0 / 1 MB"
    end

    test "format_memory returns em-dash on missing fields" do
      assert Sys.format_memory(%{}) == "—"
    end
  end

  describe "parse_df_output/1" do
    test "parses df -B1 output into used/total" do
      out = """
      Filesystem           1-blocks       Used Available Use% Mounted on
      /dev/mmcblk0p7       124927852544   8630272 118525952000   0% /root
      """

      assert Sys.parse_df_output(out) == "8.2 MB / 116 GB"
    end

    test "returns em-dash on garbage" do
      assert Sys.parse_df_output("nothing useful") == "—"
    end
  end

  describe "raw metric parse helpers" do
    test "cpu_temp_c_from parses millidegrees to °C" do
      assert Sys.cpu_temp_c_from("47200\n") == 47.2
      assert Sys.cpu_temp_c_from("garbage") == nil
    end

    test "mem_used_pct_from computes percent used" do
      # used = 831568 - 754872 = 76696 → 9% of 831568
      fields = %{"MemTotal" => 831_568, "MemAvailable" => 754_872}
      assert Sys.mem_used_pct_from(fields) == 9
    end

    test "mem_used_pct_from falls back to MemFree and guards missing/zero" do
      assert Sys.mem_used_pct_from(%{"MemTotal" => 1000, "MemFree" => 250}) == 75
      assert Sys.mem_used_pct_from(%{}) == nil
      assert Sys.mem_used_pct_from(%{"MemTotal" => 0, "MemFree" => 0}) == nil
    end

    test "load1_from parses the 1-minute load average" do
      assert Sys.load1_from("0.42 0.31 0.27 1/123 4567\n") == 0.42
      assert Sys.load1_from("nope") == nil
    end

    test "data_used_pct_from parses df -B1 percent used" do
      out = """
      Filesystem     1-blocks   Used Available Use% Mounted on
      /dev/mmcblk0p4 1000       250  750       25% /data
      """

      assert Sys.data_used_pct_from(out) == 25
      assert Sys.data_used_pct_from("nothing useful") == nil
    end
  end

  describe "metrics/1" do
    test "returns numerics from injected fixture paths" do
      tmp = make_tmp_dir!("metrics")
      thermal = Path.join(tmp, "temp")
      meminfo = Path.join(tmp, "meminfo")
      loadavg = Path.join(tmp, "loadavg")
      File.write!(thermal, "51500\n")
      File.write!(meminfo, "MemTotal: 1000 kB\nMemAvailable: 600 kB\n")
      File.write!(loadavg, "1.50 0.80 0.40 1/99 1234\n")

      m = Sys.metrics(thermal_path: thermal, meminfo_path: meminfo, loadavg_path: loadavg)

      assert m.cpu_temp_c == 51.5
      assert m.mem_used_pct == 40
      assert m.load1 == 1.5
      assert is_integer(m.boot_time_unix)
      # data_used_pct uses real `df` against the default /data; tolerate nil on host
      assert is_nil(m.data_used_pct) or is_integer(m.data_used_pct)
    end

    test "missing source files yield nil, not a crash" do
      m =
        Sys.metrics(thermal_path: "/no/such", meminfo_path: "/no/such", loadavg_path: "/no/such")

      assert m.cpu_temp_c == nil
      assert m.mem_used_pct == nil
      assert m.load1 == nil
    end
  end

  describe "boot_time_unix/0" do
    test "is roughly now minus uptime" do
      now = System.system_time(:second)
      bt = Sys.boot_time_unix()
      assert bt <= now
      # boot time can't be in the future and shouldn't predate the epoch
      assert bt > 0
    end
  end

  describe "factory_reset/1" do
    test "wipes the data root contents and skips reboot when asked" do
      root = make_tmp_dir!("factory")
      File.write!(Path.join(root, "audio_outputs.dets"), "x")
      File.mkdir_p!(Path.join(root, "bluetooth"))
      File.write!(Path.join([root, "bluetooth", "state"]), "y")

      assert Sys.factory_reset(data_root: root, reboot: false, sleep_ms: 0) == :ok
      assert File.dir?(root)
      assert File.ls!(root) == []
    end

    test "is a no-op for a non-existent data root" do
      assert Sys.factory_reset(data_root: "/no/such/data/root", reboot: false) == :unavailable
    end
  end

  defp make_tmp_dir!(prefix) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "up_system_test_#{prefix}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  describe "wifi_info/1" do
    test "returns ssid + rssi when associated" do
      # Plain map mirrors the %VintageNetWiFi.AccessPoint{} shape (the
      # struct itself is a target-only dep, not compiled on host).
      get = fn ["interface", "wlan0", "wifi", "current_ap"] ->
        %{ssid: "HomeNet", signal_dbm: -57, signal_percent: 60}
      end

      assert Sys.wifi_info(vintage_get: get) == %{ssid: "HomeNet", rssi_dbm: -57}
    end

    test "returns nil when not associated (current_ap nil)" do
      get = fn _ -> nil end
      assert Sys.wifi_info(vintage_get: get) == nil
    end

    test "returns nil for an empty/garbage current_ap" do
      assert Sys.wifi_info(vintage_get: fn _ -> %{ssid: "", signal_dbm: -99} end) == nil
      assert Sys.wifi_info(vintage_get: fn _ -> %{} end) == nil
    end
  end

  describe "network_type/1" do
    test "wifi when wlan0 is the connected interface" do
      get = fn
        ["interface", "wlan0", "connection"] -> :internet
        ["interface", _, "connection"] -> :disconnected
      end

      assert Sys.network_type(interfaces: ["eth0", "wlan0"], vintage_get: get) == :wifi
    end

    test "ethernet when eth0 is connected" do
      get = fn
        ["interface", "eth0", "connection"] -> :lan
        _ -> :disconnected
      end

      assert Sys.network_type(interfaces: ["eth0", "wlan0"], vintage_get: get) == :ethernet
    end

    test "disconnected when nothing is connected" do
      get = fn _ -> :disconnected end
      assert Sys.network_type(interfaces: ["eth0", "wlan0"], vintage_get: get) == :disconnected
    end
  end

  describe "health/1" do
    @tag :integration
    test "reads from real /proc and sysfs (host-tolerant)" do
      h = Sys.health()
      # All fields must be strings (em-dash if unavailable).
      for {key, val} <- h do
        assert is_binary(val), "expected #{inspect(key)} to be a string, got #{inspect(val)}"
      end
    end
  end

  describe "recent_log/1" do
    test "returns {entries, next_since} tuple" do
      # On host RingLogger may or may not have entries; just verify shape.
      assert {entries, next_since} = Sys.recent_log(count: 10)
      assert is_list(entries)
      assert is_integer(next_since)
      assert next_since >= 0

      Enum.each(entries, fn entry ->
        assert Map.has_key?(entry, :timestamp)
        assert Map.has_key?(entry, :level)
        assert Map.has_key?(entry, :message)
      end)
    end

    test "incremental fetch returns new entries past the cursor" do
      # We can't reliably write log entries here without coupling to the
      # RingLogger backend, so just confirm shape and monotonicity.
      {_initial, since1} = Sys.recent_log(count: 10)
      {new, since2} = Sys.recent_log(since: since1, count: 10)
      assert is_list(new)
      assert since2 >= since1
    end
  end
end
