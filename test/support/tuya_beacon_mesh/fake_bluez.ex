defmodule UniversalProxy.TuyaBeaconMesh.FakeBluez do
  @moduledoc """
  In-memory fakes for the `Bluez.*` modules `UniversalProxy.TuyaBeaconMesh.Radio` drives, so
  the queue / fan-out logic is testable off-board. One Agent (named
  `UniversalProxy.TuyaBeaconMesh.FakeBluez.State`) holds everything: recorded MGMT and D-Bus
  calls and the receiver's `on_report` fun. Compile-only test support,
  never deployed.
  """

  @agent __MODULE__.State

  # Unlinked on purpose: a linked agent would die with whichever test
  # process happened to start it first, racing the next test's setup.
  def ensure_started do
    case Process.whereis(@agent) do
      nil ->
        case Agent.start(fn -> fresh() end, name: @agent) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  def reset, do: Agent.update(@agent, fn _ -> fresh() end)

  defp fresh, do: %{calls: [], on_report: nil}

  @doc false
  def record(entry), do: Agent.update(@agent, &%{&1 | calls: [entry | &1.calls]})

  @doc "Recorded calls across all fakes, oldest first."
  def calls, do: @agent |> Agent.get(& &1.calls) |> Enum.reverse()

  def set_on_report(fun), do: Agent.update(@agent, &%{&1 | on_report: fun})

  @doc "Feeds a fake HCI report (`%{address, data, rssi}`) to the receiver."
  def inject(report) do
    case Agent.get(@agent, & &1.on_report) do
      nil -> raise "no receiver registered an on_report fun"
      fun -> fun.(report)
    end
  end

  defmodule Radio do
    @moduledoc false
    alias UniversalProxy.TuyaBeaconMesh.FakeBluez

    def start_link(_opts) do
      FakeBluez.ensure_started()
      {:ok, Process.whereis(FakeBluez.State)}
    end

    def acquire(opts), do: {:ok, %{fake_lease: Keyword.get(opts, :adapter_index, 0)}}
    def valid?(_lease), do: true
    def release(_lease), do: :ok
  end

  defmodule Mgmt do
    @moduledoc false
    alias UniversalProxy.TuyaBeaconMesh.FakeBluez

    def start_link(_opts) do
      FakeBluez.ensure_started()
      {:ok, Process.whereis(FakeBluez.State)}
    end

    def advertise(_lease, data, opts) do
      FakeBluez.ensure_started()
      FakeBluez.record({:advertise, data, opts})
      {:ok, 5}
    end

    def stop_advertising(_lease, instance) do
      FakeBluez.ensure_started()
      FakeBluez.record({:stop, instance})
      :ok
    end
  end

  defmodule Rebus do
    @moduledoc false
    alias UniversalProxy.TuyaBeaconMesh.FakeBluez

    def connect(:system) do
      FakeBluez.ensure_started()
      {:ok, Process.whereis(FakeBluez.State)}
    end
  end

  defmodule DBus do
    @moduledoc false
    alias UniversalProxy.TuyaBeaconMesh.FakeBluez

    def call(_conn, _path, _interface, member, _signature, _args) do
      FakeBluez.ensure_started()
      FakeBluez.record({:dbus, member})
      {:ok, []}
    end
  end

  defmodule Receiver do
    @moduledoc false
    use GenServer

    alias UniversalProxy.TuyaBeaconMesh.FakeBluez

    def start_link(opts) do
      {name, opts} = Keyword.pop(opts, :name, __MODULE__)
      GenServer.start_link(__MODULE__, opts, name: name)
    end

    def listening?(name), do: Process.whereis(name) != nil

    @impl GenServer
    def init(opts) do
      FakeBluez.ensure_started()
      FakeBluez.set_on_report(Keyword.fetch!(opts, :on_report))
      {:ok, %{}}
    end
  end
end
