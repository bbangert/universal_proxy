defmodule UniversalProxy.UART.Store do
  @moduledoc """
  DETS-backed persistence for UART device configurations.

  Stores device configs keyed by serial number so they survive reboots.
  Each config only holds the `port_type` (TTL, RS232, RS485) and a
  `friendly_name`. Serial settings (baudrate, parity, etc.) are provided
  at runtime by ESPHome clients via `SerialProxyConfigureRequest`.

  The DETS file lives on the writable data partition on Nerves
  (`/data/uart_configs.dets`) and in `_build/` on the host for development.

  Saving or deleting a config triggers an ESPHome supervisor restart
  so clients reconnect and re-read the updated device info.
  """

  use GenServer

  require Logger

  @table :uart_configs

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Save or update a device configuration keyed by serial number.

  Restarts the ESPHome supervisor to force client reconnects.
  """
  @spec save_config(String.t(), map()) :: :ok
  def save_config(serial_number, params) when is_binary(serial_number) do
    GenServer.call(__MODULE__, {:save, serial_number, params})
  end

  @doc """
  Delete a saved device configuration.

  Restarts the ESPHome supervisor to force client reconnects.
  """
  @spec delete_config(String.t()) :: :ok
  def delete_config(serial_number) when is_binary(serial_number) do
    GenServer.call(__MODULE__, {:delete, serial_number})
  end

  @doc """
  Look up a saved configuration by serial number.
  """
  @spec get_config(String.t()) :: {:ok, map()} | :error
  def get_config(serial_number) when is_binary(serial_number) do
    GenServer.call(__MODULE__, {:get, serial_number})
  end

  @doc """
  Return all saved device configurations.
  """
  @spec all_configs() :: [map()]
  def all_configs do
    GenServer.call(__MODULE__, :all)
  end

  # -- Server Callbacks --

  @impl true
  def init(_opts) do
    path = dets_path() |> to_charlist()

    case :dets.open_file(@table, file: path, type: :set) do
      {:ok, table} ->
        Logger.info("UART config store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("UART config store failed to open: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  @impl true
  def handle_call({:save, serial_number, params}, _from, state) do
    config =
      params
      |> normalize_config()
      |> Map.put(:serial_number, serial_number)
      |> Map.put_new(:friendly_name, "tty#{serial_number}")

    :dets.insert(state.table, {serial_number, config})
    :dets.sync(state.table)
    restart_esphome()
    {:reply, :ok, state}
  end

  def handle_call({:delete, serial_number}, _from, state) do
    :dets.delete(state.table, serial_number)
    :dets.sync(state.table)
    restart_esphome()
    {:reply, :ok, state}
  end

  def handle_call({:get, serial_number}, _from, state) do
    result =
      case :dets.lookup(state.table, serial_number) do
        [{^serial_number, config}] -> {:ok, config}
        [] -> :error
      end

    {:reply, result, state}
  end

  def handle_call(:all, _from, state) do
    configs =
      :dets.foldl(fn {_key, config}, acc -> [config | acc] end, [], state.table)

    {:reply, configs, state}
  end

  # -- Private --

  defp dets_path do
    if File.dir?("/data") do
      "/data/uart_configs.dets"
    else
      Path.join([File.cwd!(), "_build", "uart_configs.dets"])
    end
  end

  defp normalize_config(params) when is_map(params) do
    %{
      port_type: to_atom(params[:port_type] || params["port_type"], :ttl)
    }
  end

  defp to_atom(val, _default) when is_atom(val), do: val
  defp to_atom(val, default) when is_binary(val) do
    case val do
      "" -> default
      s -> String.to_existing_atom(s)
    end
  rescue
    ArgumentError -> default
  end
  defp to_atom(_, default), do: default

  defp restart_esphome do
    Task.start(fn ->
      UniversalProxy.ESPHome.Supervisor.restart()
    end)
  end
end
