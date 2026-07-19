defmodule UniversalProxy.UART.SettingsStore do
  @moduledoc """
  DETS-backed persistence for per-port UART line settings (last successful
  open).

  Remembers, per physical port, the line settings (`:speed`, `:data_bits`,
  `:stop_bits`, `:parity`, `:flow_control`) the port was last successfully
  opened with. This is UART-domain data; the writer today is the ESPHome
  serial-proxy adapter (`UniversalProxy.ESPHome.SerialProxy.open/3`), and
  there are two readers: the adapter's `default_open_opts/1` (espex 0.8
  lazily opens an instance for a client that resumed after a proxy restart
  without re-sending a `SerialProxyConfigureRequest` — real ESPHome
  hardware retains its UART settings across a reconnect, so clients
  legitimately assume the proxy does too) and `UniversalProxy.Hardware.
  list_ports/0` (decorates the Overview drawer's "Serial settings" row).

  Keyed by `UniversalProxy.Hardware`'s stable port id (`"p_" <> slot`),
  which survives replug on the same physical port.

  Entries are tagged with the USB serial number of the device that wrote
  them. A port id changes hands when `UniversalProxy.UART.Server` sees
  the slot's USB serial number disappear from a hotplug poll and calls
  `delete_opts/3` with the departed serial — the delete only fires when
  the stored tag still matches, so a different adapter that replugs into
  the slot and re-persists its own settings *before* the poll notices the
  swap keeps its fresh entry (the delayed clear no-ops on the tag
  mismatch). Records written before tagging existed (2-tuples) are read
  normally and treated as matching any serial on delete — clearing them
  is exactly the pre-tagging behavior.

  The DETS file lives on the writable data partition on Nerves
  (`/data/uart_settings.dets`) and in `_build/` on the host for
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
  Persist the line settings a port was last successfully opened with,
  tagged with the writing device's USB `serial` (or `nil` when the
  adapter reports none). Stores only the line-setting keys
  (`#{inspect(@settings_keys)}`), discarding anything else
  (e.g. `:friendly_name`). Writes + syncs DETS.
  """
  @spec put_opts(GenServer.server(), String.t(), keyword(), String.t() | nil) ::
          :ok | {:error, term()}
  def put_opts(server \\ __MODULE__, port_id, opts, serial \\ nil) when is_binary(port_id) do
    GenServer.call(server, {:put, port_id, Keyword.take(opts, @settings_keys), serial})
  end

  @doc """
  Return the persisted line settings for `port_id`, or `nil` if the port
  has never been successfully opened (or the store has no record of it).
  """
  @spec get_opts(GenServer.server(), String.t()) :: keyword() | nil
  def get_opts(server \\ __MODULE__, port_id) when is_binary(port_id) do
    GenServer.call(server, {:get, port_id})
  end

  @doc """
  Forget the persisted line settings for `port_id`. Called by
  `UniversalProxy.UART.Server` when the adapter in that slot is
  unplugged. With `expected_serial` (the departed device's USB serial),
  the delete only fires when the stored tag matches — a different
  adapter's fresher write survives a delayed clear. `:any` deletes
  unconditionally; untagged legacy records match any serial. Deleting an
  absent id is a no-op `:ok`.
  """
  @spec delete_opts(GenServer.server(), String.t(), String.t() | :any) :: :ok | {:error, term()}
  def delete_opts(server \\ __MODULE__, port_id, expected_serial \\ :any)
      when is_binary(port_id) and (is_binary(expected_serial) or expected_serial == :any) do
    GenServer.call(server, {:delete, port_id, expected_serial})
  end

  @doc """
  Snapshot of every persisted port's line settings, keyed by port id.
  Used by `Hardware.list_ports/0` to decorate port maps in one call
  instead of N lookups.
  """
  @spec all_opts(GenServer.server()) :: %{String.t() => keyword()}
  def all_opts(server \\ __MODULE__) do
    GenServer.call(server, :all)
  end

  # -- Server Callbacks --

  @impl GenServer
  def init(opts) do
    table_name = Keyword.get(opts, :table, :uart_settings)
    path = Keyword.get(opts, :dets_path) || dets_path()

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        Logger.info("UART settings store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("UART settings store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl GenServer
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  @impl GenServer
  def handle_call({:put, port_id, opts, serial}, _from, state) do
    with :ok <- :dets.insert(state.table, {port_id, opts, serial}),
         :ok <- :dets.sync(state.table) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("UART settings store write failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, port_id}, _from, state) do
    {:reply, read_opts(state.table, port_id), state}
  end

  def handle_call({:delete, port_id, expected_serial}, _from, state) do
    if serial_matches?(state.table, port_id, expected_serial) do
      with :ok <- :dets.delete(state.table, port_id),
           :ok <- :dets.sync(state.table) do
        {:reply, :ok, state}
      else
        {:error, reason} ->
          Logger.error("UART settings store delete failed: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    else
      # Tag mismatch: the entry was re-written by a different device after
      # the caller snapshotted its serial — leave the fresher write alone.
      {:reply, :ok, state}
    end
  end

  def handle_call(:all, _from, state) do
    all =
      :dets.foldl(
        fn
          {id, opts, _serial}, acc -> Map.put(acc, id, opts)
          {id, opts}, acc -> Map.put(acc, id, opts)
        end,
        %{},
        state.table
      )

    {:reply, all, state}
  end

  # -- Private --

  # Records are `{port_id, opts, serial}`; 2-tuples predate serial tagging
  # and are read identically (and match any serial on delete).
  defp read_opts(table, port_id) do
    case :dets.lookup(table, port_id) do
      [{^port_id, opts, _serial}] -> opts
      [{^port_id, opts}] -> opts
      _ -> nil
    end
  end

  defp serial_matches?(_table, _port_id, :any), do: true

  defp serial_matches?(table, port_id, expected) do
    case :dets.lookup(table, port_id) do
      [{^port_id, _opts, serial}] -> serial in [expected, nil]
      # Legacy untagged record: clearing it is the pre-tagging behavior.
      [{^port_id, _opts}] -> true
      # Absent: deleting is a no-op either way.
      _ -> true
    end
  end

  defp dets_path do
    if File.dir?("/data") do
      "/data/uart_settings.dets"
    else
      Path.join([File.cwd!(), "_build", "uart_settings.dets"])
    end
  end
end
