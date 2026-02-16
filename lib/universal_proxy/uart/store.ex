defmodule UniversalProxy.UART.Store do
  @moduledoc """
  DETS-backed persistence for UART device configurations.

  Stores device configs keyed by serial number so they survive reboots.
  The DETS file lives on the writable data partition on Nerves
  (`/data/uart_configs.dets`) and in `_build/` on the host for development.
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
  """
  @spec save_config(String.t(), map()) :: :ok
  def save_config(serial_number, params) when is_binary(serial_number) do
    GenServer.call(__MODULE__, {:save, serial_number, params})
  end

  @doc """
  Delete a saved device configuration.
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

  @doc """
  Return only configs that have `auto_open: true`.
  """
  @spec auto_open_configs() :: [map()]
  def auto_open_configs do
    GenServer.call(__MODULE__, :auto_open)
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
    {:reply, :ok, state}
  end

  def handle_call({:delete, serial_number}, _from, state) do
    :dets.delete(state.table, serial_number)
    :dets.sync(state.table)
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

  def handle_call(:auto_open, _from, state) do
    configs =
      :dets.foldl(
        fn {_key, config}, acc ->
          if config[:auto_open], do: [config | acc], else: acc
        end,
        [],
        state.table
      )

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
      speed: to_integer(params[:speed] || params["speed"], 9600),
      data_bits: to_integer(params[:data_bits] || params["data_bits"], 8),
      stop_bits: to_integer(params[:stop_bits] || params["stop_bits"], 1),
      parity: to_atom(params[:parity] || params["parity"], :none),
      flow_control: to_atom(params[:flow_control] || params["flow_control"], :none),
      auto_open: to_boolean(params[:auto_open] || params["auto_open"], false)
    }
  end

  defp to_integer(val, _default) when is_integer(val), do: val
  defp to_integer(val, default) when is_binary(val) do
    case Integer.parse(val) do
      {n, _} -> n
      :error -> default
    end
  end
  defp to_integer(_, default), do: default

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

  defp to_boolean(true, _), do: true
  defp to_boolean("true", _), do: true
  defp to_boolean("on", _), do: true
  defp to_boolean(_, default), do: default
end
