defmodule UniversalProxy.ESPHome.ConfigStore do
  @moduledoc """
  DETS-backed persistence for ESPHome device identity overrides.

  Holds the user-edited fields applied on top of the built-in defaults
  before they are passed to `Espex.start_link/1`. The active running
  config is owned by `Espex.Server`; this store only persists the
  *intended* values across restarts and reboots.

  The DETS file lives on the writable data partition on Nerves
  (`/data/esphome_config.dets`) and in `_build/` on the host for
  development.
  """

  use GenServer

  require Logger

  @config_key :device_config
  @default_port 6053

  @defaults %{
    name: "universal-proxy",
    friendly_name: "Universal Proxy",
    esphome_version: "2026.1.0",
    model: "Universal Proxy",
    manufacturer: "UniversalProxy",
    suggested_area: "",
    # ESPHome's "author.project" convention — Home Assistant splits on
    # the dot to derive the model. A bare token (no dot) makes HA's
    # discovery task crash silently. Empty string is the safe "no
    # project" value.
    project_name: "bbangert.universal_proxy",
    project_version: "0.1.0",
    port: @default_port
  }

  @config_fields Map.keys(@defaults) ++ [:mac_address, :compilation_time]

  # -- Client API --

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Return the merged keyword list to pass as `:device_config` when
  starting `Espex`.
  """
  @spec device_config_opts(GenServer.server()) :: keyword()
  def device_config_opts(server \\ __MODULE__) do
    GenServer.call(server, :device_config_opts)
  end

  @doc """
  Return the full configuration as a map (defaults merged with overrides).
  """
  @spec current(GenServer.server()) :: map()
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  end

  @doc """
  Persist the given keyword list of overrides. Unknown keys are ignored.
  """
  @spec put(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def put(server \\ __MODULE__, updates) when is_list(updates) do
    GenServer.call(server, {:put, updates})
  end

  @doc """
  Returns the metadata used by `UniversalProxyWeb.ESPhomeConfigLive` to
  render the form (field key, label, description).
  """
  @spec form_fields() :: [{atom(), String.t(), String.t()}]
  def form_fields do
    [
      {:name, "Device Name", "Hostname used in mDNS and the Native API"},
      {:friendly_name, "Friendly Name", "Human-readable name shown in dashboards"},
      {:mac_address, "MAC Address", "Hardware address reported to clients"},
      {:esphome_version, "ESPHome Version", "Emulated ESPHome firmware version"},
      {:model, "Model", "Device hardware model"},
      {:manufacturer, "Manufacturer", "Device manufacturer"},
      {:suggested_area, "Suggested Area", "Default area hint for Home Assistant"},
      {:project_name, "Project Name",
       "Must follow ESPHome's author.project format (e.g. acme.thermostat). " <>
         "Leave blank for no project; values without a dot are stripped."},
      {:project_version, "Project Version", "Project version string"},
      {:port, "API Port", "TCP port for the ESPHome Native API (requires restart)"}
    ]
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, :esphome_config)
    path = (Keyword.get(opts, :dets_path) || dets_path()) |> to_charlist()

    case :dets.open_file(table_name, file: path, type: :set) do
      {:ok, table} ->
        Logger.info("ESPHome config store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("ESPHome config store failed to open: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  @impl true
  def handle_call(:device_config_opts, _from, state) do
    {:reply, build_opts(state), state}
  end

  def handle_call(:current, _from, state) do
    overrides = read_overrides(state.table)
    {:reply, Map.merge(@defaults, overrides), state}
  end

  def handle_call({:put, updates}, _from, state) do
    sanitized = sanitize(updates)
    overrides = read_overrides(state.table) |> Map.merge(sanitized)

    with :ok <- write_overrides(state.table, overrides),
         :ok <- sync(state.table) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("ESPHome config store write failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # -- Private --

  defp write_overrides(table, overrides) do
    case :dets.insert(table, {@config_key, overrides}) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp sync(table) do
    case :dets.sync(table) do
      :ok -> :ok
      {:error, _} = err -> err
    end
  end

  defp build_opts(state) do
    overrides = read_overrides(state.table)

    @defaults
    |> Map.merge(overrides)
    |> Map.to_list()
  end

  defp read_overrides(table) do
    case :dets.lookup(table, @config_key) do
      [{@config_key, overrides}] when is_map(overrides) -> overrides
      _ -> %{}
    end
  end

  # Normalised values that should be silently dropped (rather than persisted).
  # Returning :skip from a normaliser means "this update is bogus — leave the
  # existing override (or the default) in place".
  @skip :skip
  @valid_port_range 1..65_535

  defp sanitize(updates) do
    updates
    |> Enum.flat_map(fn
      {k, v} when k in @config_fields ->
        case normalize(k, v) do
          @skip -> []
          normalized -> [{k, normalized}]
        end

      _ ->
        []
    end)
    |> Map.new()
  end

  defp normalize(:port, v) when is_integer(v) and v in @valid_port_range, do: v

  defp normalize(:port, v) when is_integer(v) do
    Logger.warning(
      "ESPHome port #{v} out of range #{inspect(@valid_port_range)}; ignoring update"
    )

    @skip
  end

  defp normalize(:port, v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} when n in @valid_port_range ->
        n

      _ ->
        Logger.warning(~s|ESPHome port "#{v}" is not a valid TCP port; falling back to default|)
        @default_port
    end
  end

  defp normalize(:port, _), do: @skip

  defp normalize(:project_name, v) when is_binary(v) do
    trimmed = String.trim(v)

    cond do
      trimmed == "" ->
        ""

      String.contains?(trimmed, ".") ->
        trimmed

      true ->
        Logger.warning(
          ~s|ESPHome project_name "#{trimmed}" must follow author.project format; ignoring (Home Assistant discovery would otherwise crash silently)|
        )

        ""
    end
  end

  defp normalize(:project_name, _), do: @skip

  defp normalize(_, v) when is_binary(v), do: v
  defp normalize(_, nil), do: @skip
  defp normalize(_, v) when is_atom(v), do: Atom.to_string(v)

  defp normalize(key, v) do
    Logger.warning("ESPHome config #{inspect(key)} got unsupported value #{inspect(v)}; ignoring")
    @skip
  end

  defp dets_path do
    if File.dir?("/data") do
      "/data/esphome_config.dets"
    else
      Path.join([File.cwd!(), "_build", "esphome_config.dets"])
    end
  end
end
