defmodule UniversalProxy.System do
  @moduledoc """
  Live system info for the System tab — firmware metadata, health
  stats, recent logs, reboot.

  All sources are read-on-demand (cheap on a Pi 3) so the LiveView can
  poll on a short interval. Each function is wrapped to degrade
  gracefully when its data source isn't available (host dev, missing
  sysfs file, optional dep absent).
  """

  # These modules only exist on Nerves targets / when their apps are
  # running. Reference them at compile time without warning; runtime
  # `Code.ensure_loaded?` checks gate every call.
  @compile {:no_warn_undefined, [Nerves.Runtime, Nerves.Runtime.KV, VintageNet, RingLogger]}

  # Captured at compile time. `Mix` is a build-time tool and isn't
  # loaded in mix releases on Nerves, so calling `Mix.target/0` at
  # runtime would raise `UndefinedFunctionError`.
  @target Mix.target() |> to_string()

  # ── Firmware metadata ──────────────────────────────────────────────

  @doc """
  Read static firmware identity from `Nerves.Runtime.KV` and the
  device tree.
  """
  @spec firmware_info(keyword()) :: map()
  def firmware_info(opts \\ []) do
    kv = Keyword.get_lazy(opts, :kv, &kv_active/0)

    %{
      version: kv["nerves_fw_version"] || application_version(),
      target: kv["nerves_fw_platform"] || @target,
      hardware: device_tree_model() || host_label(),
      uuid: kv["nerves_fw_uuid"],
      vcs_identifier: blank_to_nil(kv["nerves_fw_vcs_identifier"]),
      validated: kv["nerves_fw_validated"] == "1",
      author: blank_to_nil(kv["nerves_fw_author"]),
      product: kv["nerves_fw_product"],
      architecture: kv["nerves_fw_architecture"]
    }
  end

  defp kv_active do
    if Code.ensure_loaded?(Nerves.Runtime.KV),
      do: Nerves.Runtime.KV.get_all_active(),
      else: %{}
  end

  defp application_version do
    case :application.get_key(:universal_proxy, :vsn) do
      {:ok, vsn} -> to_string(vsn)
      _ -> "—"
    end
  end

  defp device_tree_model do
    case File.read("/proc/device-tree/model") do
      {:ok, s} -> s |> String.trim_trailing(<<0>>) |> String.trim() |> blank_to_nil()
      _ -> nil
    end
  end

  defp host_label do
    {:ok, name} = :inet.gethostname()
    "Host (#{name})"
  end

  @doc """
  Compact device identity for the Overview tab's summary card:
  hostname (`.local`), primary IPv4, hardware string, firmware version.
  Each field falls back to "—" if its source is unavailable.
  """
  @spec device_summary() :: %{
          hostname: String.t(),
          ip: String.t(),
          hardware: String.t(),
          firmware: String.t()
        }
  def device_summary do
    fw = firmware_info()

    %{
      hostname: hostname(),
      ip: primary_ipv4(),
      hardware: fw.hardware || "—",
      firmware: fw.version || "—"
    }
  end

  defp hostname do
    {:ok, name} = :inet.gethostname()
    "#{name}.local"
  end

  defp primary_ipv4 do
    if Code.ensure_loaded?(VintageNet) do
      VintageNet.all_interfaces()
      |> Enum.find_value(fn iface ->
        if VintageNet.get(["interface", iface, "connection"]) == :internet do
          ipv4_address(iface)
        end
      end) || "—"
    else
      "—"
    end
  end

  defp ipv4_address(iface) do
    addrs = VintageNet.get(["interface", iface, "addresses"]) || []

    Enum.find_value(addrs, fn
      %{family: :inet, scope: :universe, address: tuple} ->
        tuple |> Tuple.to_list() |> Enum.join(".")

      _ ->
        nil
    end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  # ── Health ────────────────────────────────────────────────────────

  @doc """
  Read live system health metrics. Each metric falls back to `"—"` if
  its source is unavailable.
  """
  @spec health(keyword()) :: map()
  def health(opts \\ []) do
    %{
      uptime: format_uptime(uptime_seconds()),
      load_avg: load_avg(),
      memory: memory(),
      cpu_temp: cpu_temp(),
      storage: storage(Keyword.get(opts, :data_path, "/root")),
      network: network_summary()
    }
  end

  # -- Uptime ---------------------------------------------------------

  defp uptime_seconds do
    {ms, _} = :erlang.statistics(:wall_clock)
    div(ms, 1000)
  end

  defp format_uptime(seconds) when is_integer(seconds) do
    days = div(seconds, 86_400)
    hours = div(rem(seconds, 86_400), 3600)
    mins = div(rem(seconds, 3600), 60)

    cond do
      days > 0 -> "#{days} d #{hours} h"
      hours > 0 -> "#{hours} h #{mins} m"
      true -> "#{mins} m"
    end
  end

  # -- Load average (1-minute) ---------------------------------------

  defp load_avg do
    case File.read("/proc/loadavg") do
      {:ok, s} ->
        case String.split(s, " ") do
          [a | _] -> a
          _ -> "—"
        end

      _ ->
        "—"
    end
  end

  # -- Memory ---------------------------------------------------------

  @doc false
  @spec parse_meminfo(String.t()) :: map()
  def parse_meminfo(s) do
    s
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^(\w+):\s+(\d+)/, line) do
        [_, key, val] -> [{key, String.to_integer(val)}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp memory do
    case File.read("/proc/meminfo") do
      {:ok, s} -> format_memory(parse_meminfo(s))
      _ -> "—"
    end
  end

  @doc false
  def format_memory(fields) do
    total_kb = Map.get(fields, "MemTotal")
    avail_kb = Map.get(fields, "MemAvailable") || Map.get(fields, "MemFree")

    if total_kb && avail_kb do
      used_kb = total_kb - avail_kb
      "#{div(used_kb, 1024)} / #{div(total_kb, 1024)} MB"
    else
      "—"
    end
  end

  # -- CPU temperature ------------------------------------------------

  defp cpu_temp do
    case File.read("/sys/class/thermal/thermal_zone0/temp") do
      {:ok, s} ->
        case Integer.parse(String.trim(s)) do
          {millic, _} -> "#{Float.round(millic / 1000, 1)} °C"
          _ -> "—"
        end

      _ ->
        "—"
    end
  end

  # -- Storage --------------------------------------------------------

  defp storage(path) do
    case System.cmd("df", ["-B1", path], stderr_to_stdout: true) do
      {out, 0} -> parse_df_output(out)
      _ -> "—"
    end
  rescue
    _ -> "—"
  end

  @doc false
  def parse_df_output(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.at(1, "")
    |> String.split(~r/\s+/, trim: true)
    |> case do
      [_fs, total, used, _avail, _pct, _mount] ->
        with {t, _} <- Integer.parse(total),
             {u, _} <- Integer.parse(used) do
          "#{format_bytes(u)} / #{format_bytes(t)}"
        else
          _ -> "—"
        end

      _ ->
        "—"
    end
  end

  defp format_bytes(b) when b >= 1024 * 1024 * 1024 * 10 do
    "#{div(b, 1024 * 1024 * 1024)} GB"
  end

  defp format_bytes(b) when b >= 1024 * 1024 * 1024 do
    "#{Float.round(b / (1024 * 1024 * 1024), 1)} GB"
  end

  defp format_bytes(b) when b >= 1024 * 1024 do
    "#{Float.round(b / (1024 * 1024), 1)} MB"
  end

  defp format_bytes(b) when b >= 1024 do
    "#{div(b, 1024)} KB"
  end

  defp format_bytes(b), do: "#{b} B"

  # -- Network --------------------------------------------------------

  defp network_summary do
    if Code.ensure_loaded?(VintageNet) do
      VintageNet.all_interfaces()
      |> Enum.find_value(fn iface ->
        if VintageNet.get(["interface", iface, "connection"]) == :internet do
          format_network_iface(iface)
        end
      end) || "Disconnected"
    else
      "—"
    end
  end

  defp format_network_iface(iface) do
    type =
      case iface do
        "eth0" -> "Ethernet"
        "wlan0" -> "Wi-Fi"
        _ -> iface
      end

    case File.read("/sys/class/net/#{iface}/speed") do
      {:ok, s} ->
        case Integer.parse(String.trim(s)) do
          {n, _} when n >= 1000 -> "#{type}, #{div(n, 1000)} Gbps"
          {n, _} when n > 0 -> "#{type}, #{n} Mbps"
          _ -> type
        end

      _ ->
        type
    end
  end

  # ── System log ─────────────────────────────────────────────────────

  @doc """
  Fetch entries from `RingLogger` and return `{formatted_entries, next_since}`.

  ## Options

    * `:since` — RingLogger entry index to start from (cursor). `0` (default)
      means "snapshot the buffer's tail" — useful for initial load.
    * `:count` — soft cap on returned entries.

  Used by `SystemLive` like this: on `mount/3`, call once with no `:since`
  to seed the buffer's tail (`{entries, since}`); on each refresh tick,
  call with `since: previous_since` to fetch only new entries (cheap —
  O(new entries), not O(buffer size)).
  """
  @spec recent_log(keyword()) :: {[map()], non_neg_integer()}
  def recent_log(opts \\ []) do
    since = Keyword.get(opts, :since, 0)
    count = Keyword.get(opts, :count, 50)
    do_recent_log(since, count)
  end

  defp do_recent_log(since, count) do
    if ring_logger_available?() do
      raw =
        if since == 0 do
          # Initial load: scan the buffer once and take the tail.
          RingLogger.get(0, 5_000) |> Enum.take(-count)
        else
          # Incremental: fetch only entries past the cursor. The
          # `count * 4` cap protects against runaway buffers between
          # ticks while still capping memory.
          RingLogger.get(since, count * 4)
        end

      {Enum.flat_map(raw, &format_log_entry/1), next_index_after(raw, since)}
    else
      {[], since}
    end
  rescue
    _ -> {[], since}
  catch
    # GenServer.call exits when RingLogger.Server isn't running.
    :exit, _ -> {[], since}
  end

  defp ring_logger_available? do
    Code.ensure_loaded?(RingLogger) and Process.whereis(RingLogger.Server) != nil
  end

  defp next_index_after([], fallback), do: fallback

  defp next_index_after(entries, fallback) do
    case List.last(entries) do
      %{metadata: meta} ->
        case Keyword.get(meta, :index) do
          idx when is_integer(idx) -> idx + 1
          _ -> fallback
        end

      _ ->
        fallback
    end
  end

  defp format_log_entry(%{timestamp: ts, level: level, message: msg}) do
    [%{timestamp: format_log_timestamp(ts), level: format_level(level), message: to_string(msg)}]
  end

  defp format_log_entry(_), do: []

  defp format_log_timestamp({{y, mo, d}, {h, mi, s, _ms}}) do
    :io_lib.format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B", [y, mo, d, h, mi, s])
    |> IO.iodata_to_binary()
  end

  defp format_log_timestamp(_), do: ""

  defp format_level(:debug), do: "DEBUG"
  defp format_level(:info), do: "INFO"
  defp format_level(:notice), do: "INFO"
  defp format_level(:warning), do: "WARN"
  defp format_level(:warn), do: "WARN"
  defp format_level(:error), do: "ERROR"
  defp format_level(:critical), do: "ERROR"
  defp format_level(:alert), do: "ERROR"
  defp format_level(:emergency), do: "ERROR"
  defp format_level(other), do: other |> to_string() |> String.upcase()

  # ── Actions ────────────────────────────────────────────────────────

  @doc """
  Reboot the device. Returns immediately on host (no-op).
  """
  @spec reboot() :: :ok | :unavailable
  def reboot do
    if function_exported?(Nerves.Runtime, :reboot, 0) do
      Nerves.Runtime.reboot()
      :ok
    else
      :unavailable
    end
  end
end
