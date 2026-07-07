defmodule UniversalProxy.System do
  @moduledoc """
  Live system info for the System tab — firmware metadata, health
  stats, recent logs, reboot.

  All sources are read-on-demand (cheap on a Pi 3) so the LiveView can
  poll on a short interval. Each function is wrapped to degrade
  gracefully when its data source isn't available (host dev, missing
  sysfs file, optional dep absent).
  """

  require Logger

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
      hardware: fw.hardware,
      firmware: fw.version || "—"
    }
  end

  # Prefer the device's unique advertised alias — the ESPHome node name
  # (`universal-proxy-07507f`) that `ESPHome.MdnsAdapter` publishes as
  # `<name>.local` — so the Overview shows the hostname users should
  # actually reach for, not the OS-level `nerves-XXXX`. Reuses the
  # adapter's host-label gate so we never display a hostname that isn't
  # really advertised; falls back to the OS hostname when the name is
  # unusable or config is unavailable.
  defp hostname do
    "#{advertised_host() || os_hostname()}.local"
  end

  defp advertised_host do
    UniversalProxy.ESPHome.MdnsAdapter.host_alias(UniversalProxy.ESPHome.config().name)
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp os_hostname do
    {:ok, name} = :inet.gethostname()
    name
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

  @doc """
  Seconds since the BEAM started (a proxy for device uptime).
  """
  @spec uptime_seconds() :: non_neg_integer()
  def uptime_seconds do
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

  # ── Wi-Fi / network type ───────────────────────────────────────────
  #
  # ⚠ SPIKE (confirmed against deps/vintage_net_wifi 0.12.8): the current
  # association is published at `["interface", ifname, "wifi", "current_ap"]`
  # as a `%VintageNetWiFi.AccessPoint{}` (fields `:ssid`, `:signal_dbm`)
  # when associated, and `nil` when not. Cannot be HW-validated on the
  # Ethernet-only rpi3 testbed — verify on a real Wi-Fi unit.

  @wifi_ifname "wlan0"

  @doc """
  Current Wi-Fi association as `%{ssid, rssi_dbm}`, or `nil` when the
  device is not associated (Ethernet/disconnected, or no Wi-Fi support).

  ## Options (for tests)

    * `:vintage_get` — 1-arity fun replacing the VintageNet property read
    * `:wifi_ifname` — interface name (default `"wlan0"`)
  """
  @spec wifi_info(keyword()) :: %{ssid: String.t(), rssi_dbm: integer()} | nil
  def wifi_info(opts \\ []) do
    get = Keyword.get(opts, :vintage_get, &vintage_get/1)
    ifname = Keyword.get(opts, :wifi_ifname, @wifi_ifname)

    case get.(["interface", ifname, "wifi", "current_ap"]) do
      %{ssid: ssid, signal_dbm: dbm} when is_binary(ssid) and ssid != "" and is_integer(dbm) ->
        %{ssid: ssid, rssi_dbm: dbm}

      _ ->
        nil
    end
  end

  @doc """
  Active network medium: `:ethernet`, `:wifi`, or `:disconnected`.

  Picks the first interface that VintageNet reports as connected
  (`:internet` preferred, else `:lan`) and classifies it by name.

  ## Options (for tests)

    * `:vintage_get` — 1-arity fun replacing the VintageNet property read
    * `:interfaces` — list of interface names (default `VintageNet.all_interfaces/0`)
  """
  @spec network_type(keyword()) :: :ethernet | :wifi | :disconnected
  def network_type(opts \\ []) do
    get = Keyword.get(opts, :vintage_get, &vintage_get/1)
    interfaces = Keyword.get_lazy(opts, :interfaces, &vintage_interfaces/0)

    active =
      Enum.find(interfaces, fn iface ->
        get.(["interface", iface, "connection"]) in [:internet, :lan]
      end)

    cond do
      is_nil(active) -> :disconnected
      String.starts_with?(active, "wlan") -> :wifi
      true -> :ethernet
    end
  end

  defp vintage_get(path) do
    if Code.ensure_loaded?(VintageNet), do: VintageNet.get(path), else: nil
  end

  defp vintage_interfaces do
    if Code.ensure_loaded?(VintageNet), do: VintageNet.all_interfaces(), else: []
  end

  # ── Raw metrics (numeric, for the ESPHome EntityProvider) ──────────
  #
  # `health/1` above returns DISPLAY STRINGS ("47.2 °C", "812 / 1024 MB",
  # "—"). Home Assistant sensors need raw numbers, so these accessors
  # parse the same sources into numerics (or `nil` when unavailable).
  # The display path is left untouched to avoid web-UI regressions; the
  # small amount of parse duplication is deliberate.

  @thermal_path "/sys/class/thermal/thermal_zone0/temp"
  @meminfo_path "/proc/meminfo"
  @loadavg_path "/proc/loadavg"
  @data_path "/data"

  @doc """
  Numeric system metrics for the ESPHome diagnostic sensors. Each value
  is a number or `nil` (not `"—"`) when its source is unavailable.

  Memory and data-storage are reported as **percent used** (0–100).
  `boot_time_unix` is the Unix epoch (seconds) the device booted,
  recomputed each call so it self-corrects after the Nerves NTP
  clock-step.

  ## Options (for tests — inject fixture paths)

    * `:thermal_path`, `:meminfo_path`, `:loadavg_path` — sysfs/proc files
    * `:data_path` — partition passed to `df` for storage usage
  """
  @spec metrics(keyword()) :: %{
          cpu_temp_c: float() | nil,
          mem_used_pct: non_neg_integer() | nil,
          load1: float() | nil,
          data_used_pct: non_neg_integer() | nil,
          boot_time_unix: integer()
        }
  def metrics(opts \\ []) do
    %{
      cpu_temp_c: read_cpu_temp_c(Keyword.get(opts, :thermal_path, @thermal_path)),
      mem_used_pct: read_mem_used_pct(Keyword.get(opts, :meminfo_path, @meminfo_path)),
      load1: read_load1(Keyword.get(opts, :loadavg_path, @loadavg_path)),
      data_used_pct: read_data_used_pct(Keyword.get(opts, :data_path, @data_path)),
      boot_time_unix: boot_time_unix()
    }
  end

  @doc """
  Unix epoch (seconds) at which the device booted: now minus uptime.
  """
  @spec boot_time_unix() :: integer()
  def boot_time_unix do
    System.system_time(:second) - uptime_seconds()
  end

  defp read_cpu_temp_c(path) do
    case File.read(path) do
      {:ok, s} -> cpu_temp_c_from(s)
      _ -> nil
    end
  end

  @doc false
  @spec cpu_temp_c_from(String.t()) :: float() | nil
  def cpu_temp_c_from(s) do
    case Integer.parse(String.trim(s)) do
      {millic, _} -> Float.round(millic / 1000, 1)
      _ -> nil
    end
  end

  defp read_mem_used_pct(path) do
    case File.read(path) do
      {:ok, s} -> mem_used_pct_from(parse_meminfo(s))
      _ -> nil
    end
  end

  @doc false
  @spec mem_used_pct_from(map()) :: non_neg_integer() | nil
  def mem_used_pct_from(fields) do
    total_kb = Map.get(fields, "MemTotal")
    avail_kb = Map.get(fields, "MemAvailable") || Map.get(fields, "MemFree")

    if is_integer(total_kb) and is_integer(avail_kb) and total_kb > 0 do
      round((total_kb - avail_kb) / total_kb * 100)
    end
  end

  defp read_load1(path) do
    case File.read(path) do
      {:ok, s} -> load1_from(s)
      _ -> nil
    end
  end

  @doc false
  @spec load1_from(String.t()) :: float() | nil
  def load1_from(s) do
    with [a | _] <- s |> String.trim() |> String.split(" "),
         {f, _} <- Float.parse(a) do
      f
    else
      _ -> nil
    end
  end

  defp read_data_used_pct(path) do
    case System.cmd("df", ["-B1", path], stderr_to_stdout: true) do
      {out, 0} -> data_used_pct_from(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc false
  @spec data_used_pct_from(String.t()) :: non_neg_integer() | nil
  def data_used_pct_from(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.at(1, "")
    |> String.split(~r/\s+/, trim: true)
    |> case do
      [_fs, total, used, _avail, _pct, _mount] ->
        with {t, _} <- Integer.parse(total),
             {u, _} <- Integer.parse(used),
             true <- t > 0 do
          round(u / t * 100)
        else
          _ -> nil
        end

      _ ->
        nil
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

  @doc """
  Factory reset: wipe all persisted state on the writable data
  partition, then reboot.

  Removes everything under the data root (every DETS store plus the
  BlueZ runtime dir) so the device returns as if freshly flashed — the
  API PSK, SSH identity, and audio/bluetooth/UART config are all dropped,
  forcing Home Assistant to re-adopt. Wiping the whole directory (rather
  than an enumerated file list) ensures future stores aren't missed.

  **Destructive and irreversible.** Logs a warning and pauses briefly so
  the log line flushes before the reboot. On host (no data partition)
  this is a no-op returning `:unavailable`.

  ## Options (for tests)

    * `:data_root` — directory to wipe (default `"/data"`)
    * `:reboot` — set `false` to skip the reboot (default `true`)
    * `:sleep_ms` — pre-wipe delay (default `500`)
  """
  @spec factory_reset(keyword()) :: :ok | :unavailable
  def factory_reset(opts \\ []) do
    data_root = Keyword.get(opts, :data_root, "/data")

    cond do
      not File.dir?(data_root) ->
        :unavailable

      # Never wipe a real "/data" mount on a dev host that happens to have
      # one — the default path is only honoured on a Nerves target. Tests
      # pass an explicit `:data_root` (a temp dir) and bypass this guard.
      data_root == "/data" and not function_exported?(Nerves.Runtime, :reboot, 0) ->
        :unavailable

      true ->
        Logger.warning("FACTORY RESET requested — wiping #{data_root} and rebooting")
        Process.sleep(Keyword.get(opts, :sleep_ms, 500))
        wipe_dir_contents(data_root)

        if Keyword.get(opts, :reboot, true), do: reboot(), else: :ok
    end
  end

  # Remove the contents of a directory while keeping the mountpoint.
  defp wipe_dir_contents(root) do
    case File.ls(root) do
      {:ok, entries} ->
        Enum.each(entries, fn entry -> File.rm_rf(Path.join(root, entry)) end)

      _ ->
        :ok
    end
  end
end
