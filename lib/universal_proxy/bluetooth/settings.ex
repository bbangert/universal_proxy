defmodule UniversalProxy.Bluetooth.Settings do
  @moduledoc """
  DETS-backed persistence for the Bluetooth subsystem's user-facing
  configuration (the `/bluetooth` web tab).

  A single record holding:

      %{
        enabled: boolean(),            # gate HA-facing proxying (espex wiring)
        active_connections: boolean(), # allow HA to open GATT connections
        adapter: String.t() | nil      # selected radio MAC, nil = auto
      }

  `enabled` is NOT a power switch for the radio stack: the BlueZ subtree
  runs whenever the hardware supports it. `enabled` gates only whether the
  scanner/GATT adapters are wired into espex (and therefore whether HA
  sees any Bluetooth data) — see `UniversalProxy.Bluetooth` and
  `UniversalProxy.ESPHome.Supervisor.bluetooth_opts/2`.

  The adapter is keyed by **MAC address** (`"AA:BB:CC:DD:EE:FF"`), not by
  hci index — hci indices are assigned in probe order and are not stable
  across boots or USB hotplug. `nil` means auto-select (first/onboard
  adapter).

  This module is pure persistence: no restarts, no broadcasts. The
  consequences of a settings change (restarting espex so HA sees the new
  feature flags, or restarting the BlueZ subtree on a radio switch)
  belong to `UniversalProxy.Bluetooth`'s public API, which writes here
  first and then acts.

  The DETS file lives on the writable data partition on Nerves
  (`/data/bluetooth_config.dets`) and in `_build/` on the host for
  development. Tests can override via the `:dets_path`, `:table`, and
  `:name` options to `start_link/1` (same shape as
  `UniversalProxy.Audio.Store`).
  """

  use GenServer

  require Logger

  @default_table :bluetooth_config
  @record_key :settings

  @defaults %{enabled: true, active_connections: true, adapter: nil}

  @mac_format ~r/^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/

  @type t :: %{
          enabled: boolean(),
          active_connections: boolean(),
          adapter: String.t() | nil
        }

  # -- Client API --

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  The current settings, with defaults filled in for any field a stored
  record predates. Returns the defaults map verbatim on a fresh store.
  """
  @spec get(GenServer.server()) :: t()
  def get(server \\ __MODULE__) do
    GenServer.call(server, :get)
  end

  @doc "Compile-time defaults (`#{inspect(@defaults)}`), for defensive callers."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc "Persist the master Bluetooth switch."
  @spec set_enabled(GenServer.server(), boolean()) :: :ok | {:error, term()}
  def set_enabled(server \\ __MODULE__, enabled) when is_boolean(enabled) do
    GenServer.call(server, {:put, :enabled, enabled})
  end

  @doc "Persist whether HA may open active (GATT) connections."
  @spec set_active_connections(GenServer.server(), boolean()) :: :ok | {:error, term()}
  def set_active_connections(server \\ __MODULE__, allowed) when is_boolean(allowed) do
    GenServer.call(server, {:put, :active_connections, allowed})
  end

  @doc """
  Persist the selected radio as a MAC address string, or `nil` for auto.

  The MAC is normalized to uppercase (`"aa:bb..."` → `"AA:BB..."`);
  anything that isn't `nil` or a `AA:BB:CC:DD:EE:FF`-shaped string is
  rejected with `{:error, :invalid_adapter}`.
  """
  @spec set_adapter(GenServer.server(), String.t() | nil) :: :ok | {:error, term()}
  def set_adapter(server \\ __MODULE__, adapter) do
    case normalize_adapter(adapter) do
      {:ok, normalized} -> GenServer.call(server, {:put, :adapter, normalized})
      :error -> {:error, :invalid_adapter}
    end
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, @default_table)
    path = Keyword.get(opts, :dets_path) || dets_path()

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        Logger.info("Bluetooth settings store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("Bluetooth settings store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, read(state.table), state}
  end

  def handle_call({:put, key, value}, _from, state) do
    merged = state.table |> read() |> Map.put(key, value)

    with :ok <- :dets.insert(state.table, {@record_key, merged}),
         :ok <- :dets.sync(state.table) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("Bluetooth settings save failed (#{key}): #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # -- Private --

  # Merge over the defaults so records written by an older firmware (fewer
  # fields) read back complete, and a corrupt/foreign record degrades to
  # the defaults instead of crashing every reader.
  defp read(table) do
    case :dets.lookup(table, @record_key) do
      [{@record_key, stored}] when is_map(stored) -> sanitize(Map.merge(@defaults, stored))
      _ -> @defaults
    end
  end

  # The setters validate writes, but the file can outlive them (corrupt
  # sector, hand-edited DETS, a buggy future firmware). Per-field type
  # validation on READ keeps lifecycle logic safe: a non-boolean `enabled`
  # would otherwise raise BadBooleanError inside the Manager's reconcile.
  # Also drops unknown keys, so readers always get exactly this shape.
  defp sanitize(stored) do
    %{
      enabled: bool_or(stored.enabled, @defaults.enabled),
      active_connections: bool_or(stored.active_connections, @defaults.active_connections),
      adapter: stored_adapter(stored.adapter)
    }
  end

  defp bool_or(value, _default) when is_boolean(value), do: value
  defp bool_or(_value, default), do: default

  defp stored_adapter(mac) do
    case normalize_adapter(mac) do
      {:ok, normalized} -> normalized
      :error -> nil
    end
  end

  defp normalize_adapter(nil), do: {:ok, nil}

  defp normalize_adapter(mac) when is_binary(mac) do
    if Regex.match?(@mac_format, mac), do: {:ok, String.upcase(mac)}, else: :error
  end

  defp normalize_adapter(_), do: :error

  defp dets_path do
    if File.dir?("/data") do
      "/data/bluetooth_config.dets"
    else
      Path.join([File.cwd!(), "_build", "bluetooth_config.dets"])
    end
  end
end
