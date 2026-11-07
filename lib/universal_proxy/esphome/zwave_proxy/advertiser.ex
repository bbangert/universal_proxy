defmodule UniversalProxy.ESPHome.ZWaveProxy.Advertiser do
  @moduledoc """
  Owns the `_zwave._tcp` mDNS advertisement for `ZWaveProxy`.

  `MdnsLite`'s functions are `GenServer.call`s with a 5 s timeout. They run
  here, not in `ZWaveProxy`, so a slow MdnsLite can't stall the process
  that owns the UART. `ZWaveProxy` only casts `advertise/1` and
  `withdraw/1`; casts from one sender are ordered, so a withdraw is never
  overtaken by an earlier advertise, and a cast to a dead advertiser is a
  no-op.

  Advertising removes any entry under our id first (a predecessor killed
  before `terminate/2`, or one with a since-changed port), because MdnsLite
  keeps services in a set of whole maps and a differing map would
  duplicate. A failed registration (MdnsLite not up yet) is retried with
  backoff. While advertised, the MdnsLite table owner is monitored: if it
  restarts, the dynamic service is gone, so it is registered again. The
  process that asked to advertise is monitored too, so a `ZWaveProxy` that
  dies without reaching `terminate/2` doesn't leave a stale advertisement.

  Withdrawing says goodbye (TTL 0) BEFORE removing, since removing strips
  the service the goodbye packet is built from.

  ## Options

    * `:name` - registered name (default `#{inspect(__MODULE__)}`; `nil`
      for none)
    * `:mdns_module` - `MdnsLite`-shaped module (default `MdnsLite`)
    * `:config_fun` - yields the map with the node `:name` and API `:port`
    * `:table_fun` - yields the pid of the process holding the dynamic
      services, or nil (default: the registered `MdnsLite.TableServer`)
  """

  use GenServer

  require Logger

  alias UniversalProxy.ESPHome.{ConfigStore, MdnsAdapter}
  alias UniversalProxy.SafeMdns

  # Registration retry backoff (MdnsLite may not be up at boot).
  @retry_ms 5_000
  @retry_max_ms 60_000
  @service_id :zwave_proxy

  defstruct [
    :retry_timer,
    :table_ref,
    :owner_ref,
    :mdns_module,
    :config_fun,
    :table_fun,
    advertised: false,
    registered: false,
    failures: 0
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc "Start (or refresh) the advertisement. Asynchronous."
  @spec advertise(GenServer.server()) :: :ok
  def advertise(server \\ __MODULE__), do: GenServer.cast(server, {:advertise, self()})

  @doc "Say goodbye and remove the advertisement. Asynchronous."
  @spec withdraw(GenServer.server()) :: :ok
  def withdraw(server \\ __MODULE__), do: GenServer.cast(server, :withdraw)

  @impl GenServer
  def init(opts) do
    # So terminate/2 runs on a supervisor shutdown and can withdraw.
    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       mdns_module: Keyword.get(opts, :mdns_module, MdnsLite),
       config_fun: Keyword.get(opts, :config_fun, &ConfigStore.current/0),
       table_fun: Keyword.get(opts, :table_fun, &__MODULE__.table_pid/0)
     }}
  end

  @impl GenServer
  def handle_cast({:advertise, owner}, state) do
    state = state |> demonitor_owner() |> Map.put(:owner_ref, Process.monitor(owner))
    {:noreply, register(%{state | advertised: true})}
  end

  def handle_cast(:withdraw, state), do: {:noreply, unregister(state)}

  @impl GenServer
  def handle_info(:retry, state) do
    state = %{state | retry_timer: nil}
    {:noreply, if(state.advertised, do: register(state), else: state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{table_ref: ref} = state) do
    Logger.debug("Z-Wave mDNS table owner went down (#{inspect(reason)}); re-registering")
    {:noreply, register(%{state | table_ref: nil, registered: false, failures: 0})}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:noreply, unregister(%{state | owner_ref: nil})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    unregister(state)
    :ok
  end

  defp register(state) do
    state = state |> cancel_retry() |> demonitor_table()
    mdns = state.mdns_module
    _ = SafeMdns.call(mdns, & &1.remove_mdns_service(@service_id))

    with {:ok, service} <- service(state),
         :ok <- SafeMdns.call(mdns, & &1.add_mdns_service(service)) do
      # Announce so passive peers see it now rather than at their next poll.
      _ = SafeMdns.call(mdns, & &1.announce_all())
      %{state | registered: true, failures: 0} |> monitor_table()
    else
      other ->
        delay = min(@retry_ms * Integer.pow(2, state.failures), @retry_max_ms)
        level = if state.failures == 0, do: :warning, else: :debug

        Logger.log(
          level,
          "Z-Wave _zwave._tcp registration failed (#{inspect(other)}); retrying in #{delay}ms"
        )

        %{
          state
          | registered: false,
            failures: state.failures + 1,
            retry_timer: Process.send_after(self(), :retry, delay)
        }
    end
  end

  defp unregister(state) do
    state = state |> cancel_retry() |> demonitor_table() |> demonitor_owner()
    mdns = state.mdns_module

    # A failed add may still have landed (call timeout), so a pending retry
    # also warrants the goodbye and remove.
    if state.registered or state.failures > 0 do
      _ = SafeMdns.call(mdns, & &1.goodbye_service(@service_id))
      _ = SafeMdns.call(mdns, & &1.remove_mdns_service(@service_id))
    end

    %{state | advertised: false, registered: false, failures: 0}
  end

  @doc false
  @spec table_pid() :: pid() | nil
  def table_pid do
    case Process.whereis(MdnsLite.TableServer) do
      pid when is_pid(pid) -> pid
      nil -> nil
    end
  end

  defp monitor_table(state) do
    case safe_table_pid(state.table_fun) do
      pid when is_pid(pid) -> %{state | table_ref: Process.monitor(pid)}
      _ -> state
    end
  end

  defp demonitor_table(%{table_ref: nil} = state), do: state

  defp demonitor_table(state) do
    Process.demonitor(state.table_ref, [:flush])
    %{state | table_ref: nil}
  end

  defp demonitor_owner(%{owner_ref: nil} = state), do: state

  defp demonitor_owner(state) do
    Process.demonitor(state.owner_ref, [:flush])
    %{state | owner_ref: nil}
  end

  defp safe_table_pid(fun) do
    fun.()
  rescue
    _ -> nil
  end

  defp cancel_retry(%{retry_timer: nil} = state), do: state

  defp cancel_retry(state) do
    _ = Process.cancel_timer(state.retry_timer)

    # A retry that fired before the cancel is already queued; drop it so it
    # isn't handled as the next one.
    receive do
      :retry -> :ok
    after
      0 -> :ok
    end

    %{state | retry_timer: nil}
  end

  # The node name and API port come from the live ESPHome config (a change
  # restarts this tree), not a literal 6053.
  defp service(state) do
    %{name: name, port: port} = state.config_fun.()

    {:ok,
     %{
       id: @service_id,
       instance_name: MdnsAdapter.instance_name(name),
       protocol: "zwave",
       transport: "tcp",
       port: port,
       txt_payload: ["protocol=esphome"]
     }}
  rescue
    e -> {:error, {:config_unavailable, Exception.message(e)}}
  catch
    :exit, reason -> {:error, {:config_unavailable, reason}}
  end
end
