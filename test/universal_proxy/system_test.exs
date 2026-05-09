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
