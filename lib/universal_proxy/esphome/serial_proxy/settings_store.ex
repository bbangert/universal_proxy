defmodule UniversalProxy.ESPHome.SerialProxy.SettingsStore do
  @moduledoc """
  DETS-backed persistence for per-port ESPHome serial-proxy line settings.

  Remembers, per physical port, the line settings (`:speed`, `:data_bits`,
  `:stop_bits`, `:parity`, `:flow_control`) the port was last successfully
  opened with by an ESPHome serial-proxy client. Served back through
  `UniversalProxy.ESPHome.SerialProxy.default_open_opts/1` when espex 0.8
  lazily opens an instance for a client that resumed after a proxy restart
  without re-sending a `SerialProxyConfigureRequest` (real ESPHome hardware
  retains its UART settings across a reconnect, so clients legitimately
  assume the proxy does too).

  Keyed by `UniversalProxy.Hardware`'s stable port id (`"p_" <> slot`),
  which survives replug on the same physical port.

  The DETS file lives on the writable data partition on Nerves
  (`/data/esphome_serial_settings.dets`) and in `_build/` on the host for
  development. It is owned at the top-level application supervisor (a peer
  to `ConfigStore`/`PskStore`, not inside `ESPHome.Supervisor`) so a
  `restart/0` of the ESPHome subtree never closes the DETS file.
  """

  use GenServer

  require Logger

  @settings_keys [:speed, :data_bits, :stop_bits, :parity, :flow_control]

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
  Persist the line settings a port was last successfully opened with.
  Stores only the line-setting keys (`#{inspect(@settings_keys)}`),
  discarding anything else (e.g. `:friendly_name`). Writes + syncs DETS.
  """
  @spec put_opts(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def put_opts(server \\ __MODULE__, port_id, opts) when is_binary(port_id) do
    GenServer.call(server, {:put, port_id, Keyword.take(opts, @settings_keys)})
  end

  @doc """
  Return the persisted line settings for `port_id`, or `nil` if the port
  has never been successfully opened (or the store has no record of it).
  """
  @spec get_opts(GenServer.server(), String.t()) :: keyword() | nil
  def get_opts(server \\ __MODULE__, port_id) when is_binary(port_id) do
    GenServer.call(server, {:get, port_id})
  end

  # -- Server Callbacks --

  @impl GenServer
  def init(opts) do
    table_name = Keyword.get(opts, :table, :esphome_serial_settings)
    path = Keyword.get(opts, :dets_path) || dets_path()

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        Logger.info("ESPHome serial settings store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("ESPHome serial settings store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  @impl GenServer
  def handle_call({:put, port_id, opts}, _from, state) do
    with :ok <- :dets.insert(state.table, {port_id, opts}),
         :ok <- :dets.sync(state.table) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("ESPHome serial settings store write failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, port_id}, _from, state) do
    {:reply, read_opts(state.table, port_id), state}
  end

  # -- Private --

  defp read_opts(table, port_id) do
    case :dets.lookup(table, port_id) do
      [{^port_id, opts}] -> opts
      _ -> nil
    end
  end

  defp dets_path do
    if File.dir?("/data") do
      "/data/esphome_serial_settings.dets"
    else
      Path.join([File.cwd!(), "_build", "esphome_serial_settings.dets"])
    end
  end
end
