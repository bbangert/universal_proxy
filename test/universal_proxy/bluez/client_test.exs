defmodule UniversalProxy.Bluez.ClientTest do
  # The Client registers under its module name, so tests here must not
  # run alongside anything else starting it (nothing on host does — the
  # Bluetooth subtree is :ignore off-target).
  use ExUnit.Case, async: false

  alias UniversalProxy.Bluez.Client

  defmodule ConnStub do
    @moduledoc """
    Minimal stand-in for a `Rebus.Connection` pid: answers the handler
    registrations `Client.init/1` performs and any other call with `:ok`.
    No D-Bus traffic ever flows in these tests (`setup: false` and an
    injected `apply_mode_fun` keep the Client away from the bus).
    """
    use GenServer

    def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(nil), do: {:ok, nil}

    @impl true
    def handle_call({:add_signal_handler, _pid}, _from, state),
      do: {:reply, make_ref(), state}

    def handle_call(_other, _from, state), do: {:reply, :ok, state}
  end

  # Explicit on_exit kills: Client and ConnStub are only *linked* to the
  # test process, and links don't propagate a :normal exit — without
  # this they'd outlive the test for the rest of the suite run.
  defp start_client(opts) do
    {:ok, conn} = ConnStub.start_link()

    {:ok, client} =
      Client.start_link(
        Keyword.merge(
          [connect_fun: fn -> {:ok, conn} end, setup: false],
          opts
        )
      )

    on_exit(fn ->
      for pid <- [client, conn], Process.alive?(pid), do: Process.exit(pid, :kill)
    end)

    {:ok, client}
  end

  test "watchdog stops the client when a transition neither completes nor dies" do
    Process.flag(:trap_exit, true)

    {:ok, client} =
      start_client(
        watchdog_ms: 100,
        apply_mode_fun: fn _conn, _engaged, _target -> Process.sleep(:infinity) end
      )

    # resume_scan starts a transition to the configured (:passive) mode;
    # the injected apply_mode_fun wedges forever, so only the watchdog
    # can unstick the state machine.
    GenServer.cast(client, :resume_scan)

    assert_receive {:EXIT, ^client, {:transition_stuck, :passive}}, 2_000
  end

  test "a killed transition task clears the wedge and the next set_mode proceeds" do
    Process.flag(:trap_exit, true)
    test_pid = self()
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    # First transition wedges (and reports its task pid so we can kill
    # it); later transitions succeed immediately.
    apply_fun = fn _conn, _engaged, _target ->
      n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

      if n == 0 do
        send(test_pid, {:task_started, self()})
        Process.sleep(:infinity)
      else
        {:ok, :monitor}
      end
    end

    {:ok, client} = start_client(watchdog_ms: 60_000, apply_mode_fun: apply_fun)

    GenServer.cast(client, :resume_scan)
    assert_receive {:task_started, task_pid}, 1_000
    Process.exit(task_pid, :kill)

    # Without the task monitor, `transition` would stay set and this
    # call would park behind it until the watchdog/call timeout. The
    # short timeout proves the :DOWN handler cleared the wedge.
    assert :ok = GenServer.call(client, {:set_mode, :passive}, 2_000)
  end
end
