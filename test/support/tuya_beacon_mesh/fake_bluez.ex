defmodule UniversalProxy.TuyaBeaconMesh.FakeBluez do
  @moduledoc """
  In-memory fakes for the `Bluez.*` modules `UniversalProxy.TuyaBeaconMesh.Radio` drives, so
  the queue / fan-out / retry logic is testable off-board. One Agent (named
  `UniversalProxy.TuyaBeaconMesh.FakeBluez.State`) holds everything: recorded calls,
  the receiver's `on_report` fun, the current lease and injected failures.
  Return shapes and lease rules follow bluez 0.4.0: `acquire` is
  idempotent for the holder and refuses another holder, `release` ends the
  lease and notifies every `subscribe`r with `{:radio_lease_ended, ref}`
  (the releaser included), `Mgmt` only sends for the current lease's
  holder and only stops instances it added under that lease. A contract
  test (`fake_bluez_test.exs`) checks every fake function exists with the
  same arity in the real module. Compile-only test support, never
  deployed.

  The Agent and the receiver names are global, so only `async: false`
  test modules may use it.

  Failures are injected per step with `fail/2` and cleared with
  `succeed/1`: `:mgmt` (`read_advertising_features`), `:bluez_radio`
  (`subscribe`), `:acquire`, `:connect`, `{:dbus, member}`, `:receiver`
  (`start_link`), `:advertise`, `:stop_advertising`, and
  `:receiver_stop` (`:hang` makes the receiver ignore a stop).
  """

  alias Bluez.Radio.Lease

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

  def reset do
    old = Agent.get_and_update(@agent, fn state -> {state, fresh()} end)
    if old.radio_pid, do: Process.exit(old.radio_pid, :kill)
    :ok
  end

  defp fresh do
    %{
      calls: [],
      on_report: nil,
      failures: %{},
      lease: nil,
      instances: %{},
      radio_pid: nil,
      radio_subs: []
    }
  end

  @doc false
  def record(entry), do: Agent.update(@agent, &%{&1 | calls: [entry | &1.calls]})

  @doc "Recorded calls across all fakes, oldest first."
  def calls, do: @agent |> Agent.get(& &1.calls) |> Enum.reverse()

  @doc "How many recorded calls are tuples tagged `tag`."
  def count(tag), do: Enum.count(calls(), &(is_tuple(&1) and elem(&1, 0) == tag))

  def set_on_report(fun), do: Agent.update(@agent, &%{&1 | on_report: fun})

  @doc "Feeds a fake HCI report (`%{address, data, rssi}`) to the receiver."
  def inject(report) do
    case Agent.get(@agent, & &1.on_report) do
      nil -> raise "no receiver registered an on_report fun"
      fun -> fun.(report)
    end
  end

  @doc "Makes `step` return `{:error, reason}` until `succeed/1`."
  def fail(step, reason), do: Agent.update(@agent, &put_in(&1.failures[step], reason))

  def succeed(step), do: Agent.update(@agent, &%{&1 | failures: Map.delete(&1.failures, step)})

  @doc false
  def failure(step) do
    ensure_started()
    Agent.get(@agent, &Map.get(&1.failures, step))
  end

  @doc "Ends the current lease the way `Bluez.Radio` does: notify subscribers."
  def end_lease do
    case Agent.get(@agent, & &1.lease) do
      nil -> :ok
      lease -> end_lease(lease.ref)
    end
  end

  @doc false
  def end_lease(ref) do
    {ended?, subs} =
      Agent.get_and_update(@agent, fn
        %{lease: %Lease{ref: ^ref}} = s ->
          {{true, s.radio_subs}, %{s | lease: nil, instances: %{}}}

        s ->
          {{false, []}, s}
      end)

    if ended?, do: Enum.each(subs, &send(&1, {:radio_lease_ended, ref}))
    :ok
  end

  # Bluez.Radio monitors the holder: a lease ends when its holder exits.
  @doc false
  def end_dead_holders_lease do
    case Agent.get(@agent, & &1.lease) do
      %Lease{holder: holder, ref: ref} -> unless Process.alive?(holder), do: end_lease(ref)
      nil -> :ok
    end

    :ok
  end

  @doc "Instance numbers currently advertising, as `%{instance => lease_ref}`."
  def instances, do: Agent.get(@agent, & &1.instances)

  @doc "Kills the fake `Bluez.Radio` process (every lease ends with it)."
  def kill_bluez_radio do
    pid =
      Agent.get_and_update(@agent, fn s ->
        {s.radio_pid, %{s | radio_pid: nil, lease: nil, radio_subs: []}}
      end)

    if pid, do: Process.exit(pid, :kill)
    :ok
  end

  @doc "Kills the most recent fake D-Bus connection."
  def kill_conn do
    {:connect, pid} = calls() |> Enum.filter(&match?({:connect, _}, &1)) |> List.last()
    Process.exit(pid, :kill)
    :ok
  end

  # A stand-in process for the fake `Bluez.Radio`, so it can be monitored
  # and killed without touching the Agent.
  @doc false
  def radio_pid do
    ensure_started()

    Agent.get_and_update(@agent, fn
      %{radio_pid: nil} = s ->
        pid = spawn(fn -> Process.sleep(:infinity) end)
        {pid, %{s | radio_pid: pid}}

      s ->
        {s.radio_pid, s}
    end)
  end

  defmodule Radio do
    @moduledoc false
    alias UniversalProxy.TuyaBeaconMesh.FakeBluez

    def subscribe(_server \\ nil) do
      case FakeBluez.failure(:bluez_radio) do
        nil ->
          pid = FakeBluez.radio_pid()
          caller = self()
          Agent.update(FakeBluez.State, &%{&1 | radio_subs: Enum.uniq([caller | &1.radio_subs])})
          {:ok, pid}

        reason ->
          {:error, reason}
      end
    end

    def acquire(opts \\ []) do
      case FakeBluez.failure(:acquire) do
        nil -> grant(Keyword.get(opts, :adapter_index, 0), self())
        reason -> refuse(reason)
      end
    end

    defp grant(index, holder) do
      radio = FakeBluez.radio_pid()
      FakeBluez.end_dead_holders_lease()

      result =
        Agent.get_and_update(FakeBluez.State, fn
          %{lease: %Lease{holder: ^holder} = lease} = s ->
            {{:existing, lease}, s}

          %{lease: %Lease{holder: other}} = s ->
            {{:held_by, other}, s}

          s ->
            lease = %Lease{
              radio: radio,
              index: index,
              mode: :mgmt,
              ref: make_ref(),
              holder: holder
            }

            {{:new, lease}, %{s | lease: lease}}
        end)

      case result do
        {:new, lease} ->
          FakeBluez.record({:acquire, lease.ref})
          {:ok, lease}

        {:existing, lease} ->
          FakeBluez.record({:acquire_again, lease.ref})
          {:ok, lease}

        {:held_by, other} ->
          refuse({:held_by, other})
      end
    end

    defp refuse(reason) do
      FakeBluez.record({:acquire_failed, reason})
      {:error, reason}
    end

    def valid?(%Lease{ref: ref}),
      do: Agent.get(FakeBluez.State, &match?(%Lease{ref: ^ref}, &1.lease))

    def release(%Lease{ref: ref}) do
      FakeBluez.record({:release, ref})
      FakeBluez.end_lease(ref)
    end
  end

  defmodule Mgmt do
    @moduledoc false
    alias UniversalProxy.TuyaBeaconMesh.FakeBluez

    def read_advertising_features(index, _server \\ nil) when is_integer(index) do
      case FakeBluez.failure(:mgmt) do
        nil ->
          {:ok,
           %{
             supported_flags: 0,
             max_adv_data_len: 31,
             max_scan_rsp_len: 31,
             max_instances: 5,
             instances: []
           }}

        reason ->
          {:error, reason}
      end
    end

    # Like the real one, repeated sends reuse one instance number.
    @instance 5

    def advertise(%Lease{} = lease, data, opts \\ []) do
      with :ok <- check_holder(lease),
           :ok <- check_lease(lease),
           nil <- FakeBluez.failure(:advertise) do
        FakeBluez.record({:advertise, data, opts})
        Agent.update(FakeBluez.State, &put_in(&1.instances[@instance], lease.ref))
        {:ok, @instance}
      else
        {:error, reason} -> {:error, reason}
        reason -> {:error, reason}
      end
    end

    def stop_advertising(%Lease{} = lease, instance, _server \\ nil) do
      FakeBluez.record({:stop, instance})

      with :ok <- check_holder(lease),
           nil <- FakeBluez.failure(:stop_advertising) do
        Agent.get_and_update(FakeBluez.State, fn s ->
          case s.instances do
            %{^instance => ref} when ref == lease.ref ->
              {:ok, %{s | instances: Map.delete(s.instances, instance)}}

            _other ->
              {{:error, :unknown_instance}, s}
          end
        end)
      else
        {:error, reason} -> {:error, reason}
        reason -> {:error, reason}
      end
    end

    defp check_holder(%Lease{holder: holder}) when holder == self(), do: :ok
    defp check_holder(_lease), do: {:error, :not_lease_holder}

    defp check_lease(%Lease{ref: ref}) do
      if Agent.get(FakeBluez.State, &match?(%Lease{ref: ^ref}, &1.lease)),
        do: :ok,
        else: {:error, :lease_expired}
    end
  end

  defmodule Rebus do
    @moduledoc false
    alias UniversalProxy.TuyaBeaconMesh.FakeBluez

    # Like the real connection: bound to (monitors) its owner, not linked.
    def connect(:system, _opts \\ []) do
      case FakeBluez.failure(:connect) do
        nil ->
          owner = self()

          pid =
            spawn(fn ->
              ref = Process.monitor(owner)

              receive do
                {:DOWN, ^ref, :process, _pid, _reason} -> :ok
              end
            end)

          FakeBluez.record({:connect, pid})
          {:ok, pid}

        reason ->
          {:error, reason}
      end
    end
  end

  defmodule DBus do
    @moduledoc false
    alias UniversalProxy.TuyaBeaconMesh.FakeBluez

    def call(conn, _path, _interface, member, _signature, body, _timeout \\ 5_000)
        when is_pid(conn) do
      case FakeBluez.failure({:dbus, member}) do
        nil ->
          FakeBluez.record({:dbus, member, body})
          {:ok, []}

        reason ->
          FakeBluez.record({:dbus_failed, member})
          {:error, reason}
      end
    end
  end

  defmodule Receiver do
    @moduledoc false
    use GenServer

    alias UniversalProxy.TuyaBeaconMesh.FakeBluez

    def start_link(opts \\ []) do
      case FakeBluez.failure(:receiver) do
        nil ->
          {name, opts} = Keyword.pop(opts, :name, __MODULE__)
          GenServer.start_link(__MODULE__, opts, name: name)

        reason ->
          {:error, reason}
      end
    end

    def listening?(name \\ __MODULE__), do: Process.whereis(name) != nil

    @impl GenServer
    def init(opts) do
      FakeBluez.set_on_report(Keyword.fetch!(opts, :on_report))
      FakeBluez.record({:receiver_started, self()})
      {:ok, %{}}
    end

    @impl GenServer
    def terminate(_reason, _state) do
      if FakeBluez.failure(:receiver_stop) == :hang, do: Process.sleep(:infinity)
      :ok
    end
  end
end
