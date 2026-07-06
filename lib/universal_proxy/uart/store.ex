defmodule UniversalProxy.UART.Store do
  @moduledoc """
  DETS-backed persistence for UART device configurations.

  Configs are keyed by a `{slot_sub, vendor_id, product_id}` tuple —
  i.e. the physical USB receptacle the adapter sits in plus the chip
  identity. Serial numbers are *not* used as the key because cheap
  USB-serial chips (CH340, PL2303 clones) frequently ship with shared
  or empty serials, so a serial-keyed config would collide between
  different adapters.

  The DETS file lives on the writable data partition on Nerves
  (`/data/uart_configs.dets`) and in `_build/` on the host for
  development.

  Saving or deleting a config triggers an ESPHome supervisor restart
  so clients reconnect and re-read the updated device info.
  """

  use GenServer

  require Logger

  @table :uart_configs

  @type port_key :: {String.t(), non_neg_integer() | nil, non_neg_integer() | nil}

  # -- Client API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Save or update a device configuration keyed by `{slot_sub, vid, pid}`.

  Restarts the ESPHome supervisor to force client reconnects.
  """
  @spec save_config(port_key(), map()) :: :ok
  def save_config({slot_sub, _vid, _pid} = key, params) when is_binary(slot_sub) do
    GenServer.call(__MODULE__, {:save, key, params})
  end

  @doc """
  Delete a saved device configuration.

  Restarts the ESPHome supervisor to force client reconnects.
  """
  @spec delete_config(port_key()) :: :ok
  def delete_config({slot_sub, _vid, _pid} = key) when is_binary(slot_sub) do
    GenServer.call(__MODULE__, {:delete, key})
  end

  @doc "Look up a saved configuration by `{slot_sub, vid, pid}`."
  @spec get_config(port_key()) :: {:ok, map()} | :error
  def get_config({slot_sub, _vid, _pid} = key) when is_binary(slot_sub) do
    GenServer.call(__MODULE__, {:get, key})
  end

  @doc "Return all saved device configurations."
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
        prune_legacy_records(table)
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
  def handle_call({:save, key, params}, _from, state) do
    # Note: we deliberately do not auto-generate a `friendly_name` if
    # the caller doesn't supply one — leaving it absent lets the
    # display layer (`Hardware.pick_name/3`) fall through to the USB
    # device-table's name (e.g. "USB Serial Adapter"), which is what a
    # user expects to see for an unlabelled port. ESPHome consumers
    # have their own fallbacks for when they need a label.
    config =
      params
      |> normalize_config()
      |> Map.merge(%{
        slot_sub: elem(key, 0),
        vendor_id: elem(key, 1),
        product_id: elem(key, 2)
      })

    :dets.insert(state.table, {key, config})
    :dets.sync(state.table)
    restart_esphome()
    {:reply, :ok, state}
  end

  def handle_call({:delete, key}, _from, state) do
    :dets.delete(state.table, key)
    :dets.sync(state.table)
    restart_esphome()
    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, state) do
    result =
      case :dets.lookup(state.table, key) do
        [{^key, config}] -> {:ok, config}
        [] -> :error
      end

    {:reply, result, state}
  end

  def handle_call(:all, _from, state) do
    configs =
      :dets.foldl(
        fn
          {{_slot_sub, _vid, _pid}, config}, acc -> [config | acc]
          # Skip legacy serial-keyed records we couldn't drop on init.
          _other, acc -> acc
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

  @valid_port_types [:ttl, :rs232, :rs485, :zwave, :infrared]

  defp normalize_config(params) when is_map(params) do
    port_type = to_atom(params[:port_type] || params["port_type"], :ttl)
    friendly_name = params[:friendly_name] || params["friendly_name"]
    serial_number = params[:serial_number] || params["serial_number"]

    %{port_type: if(port_type in @valid_port_types, do: port_type, else: :ttl)}
    |> maybe_put(:friendly_name, friendly_name)
    |> maybe_put(:serial_number, serial_number)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
    Task.Supervisor.start_child(UniversalProxy.TaskSupervisor, fn ->
      UniversalProxy.ESPHome.Supervisor.restart()
    end)
  end

  # Drop any DETS records left over from the old serial-keyed schema
  # (binary key) so they can't shadow new tuple-keyed entries.
  defp prune_legacy_records(table) do
    legacy_keys =
      :dets.foldl(
        fn
          {key, _val}, acc when not is_tuple(key) -> [key | acc]
          _, acc -> acc
        end,
        [],
        table
      )

    Enum.each(legacy_keys, &:dets.delete(table, &1))
    if legacy_keys != [], do: :dets.sync(table)
  end
end
