defmodule UniversalProxy.Bluetooth.HeldRadiosTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Bluetooth.HeldRadios

  @mac "B8:FB:B3:1B:3B:44"

  setup do
    n = System.unique_integer([:positive])
    registry = :"held_radios_test_#{n}"
    pubsub = :"held_radios_pubsub_#{n}"
    start_supervised!({HeldRadios, registry: registry})
    start_supervised!({Phoenix.PubSub, name: pubsub})
    :ok = Phoenix.PubSub.subscribe(pubsub, HeldRadios.topic())
    {:ok, opts: [registry: registry, pubsub: pubsub]}
  end

  # A process that holds `mac` until told to stop.
  defp holder(opts, mac \\ @mac, index \\ 0) do
    test = self()

    pid =
      spawn(fn ->
        :ok = HeldRadios.hold(mac, index, opts)
        send(test, :held)

        receive do
          :release ->
            :ok = HeldRadios.release(mac, opts)
            send(test, :released)
        end

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :held
    pid
  end

  test "a hold is listed with its index, holder and pid, and announced", %{opts: opts} do
    :ok = HeldRadios.hold(String.downcase(@mac), 2, opts)

    assert_receive {:bluetooth_held_changed}
    assert HeldRadios.list(opts) == [%{address: @mac, index: 2, holder: :tuya_mesh, pid: self()}]
    assert HeldRadios.held?(@mac, opts)

    # Holding again updates the entry.
    :ok = HeldRadios.hold(@mac, 3, opts)
    assert [%{index: 3}] = HeldRadios.list(opts)

    :ok = HeldRadios.release(@mac, opts)
    assert_receive {:bluetooth_held_changed}
    assert HeldRadios.list(opts) == []
    refute HeldRadios.held?(@mac, opts)
  end

  test "another process can't take a held MAC, nor release it", %{opts: opts} do
    pid = holder(opts)

    assert HeldRadios.hold(@mac, 1, opts) == {:error, :held_elsewhere}
    assert HeldRadios.release(@mac, opts) == :ok
    assert [%{pid: ^pid, index: 0}] = HeldRadios.list(opts)

    send(pid, :release)
    assert_receive :released
    assert HeldRadios.list(opts) == []
  end

  test "a holder that dies holds nothing, crash included", %{opts: opts} do
    pid = holder(opts)
    other = holder(opts, "AA:BB:CC:DD:EE:FF", 1)

    Process.exit(pid, :kill)

    # Listed only while alive, even before the Registry drops the entry.
    assert [%{address: "AA:BB:CC:DD:EE:FF", pid: ^other}] = HeldRadios.list(opts)
    refute HeldRadios.held?(@mac, opts)
  end

  test "a hold left by a holder that just died is taken over", %{opts: opts} do
    pid = holder(opts)
    Process.exit(pid, :kill)

    assert HeldRadios.hold(@mac, 1, opts) == :ok
    me = self()
    assert [%{pid: ^me, index: 1}] = HeldRadios.list(opts)
  end

  test "sorted by index", %{opts: opts} do
    holder(opts, "AA:BB:CC:DD:EE:FF", 3)
    holder(opts, @mac, 1)

    assert [%{index: 1}, %{index: 3}] = HeldRadios.list(opts)
  end

  test "without the registry everything is a no-op" do
    opts = [registry: :no_such_held_registry, pubsub: :no_such_pubsub]

    assert HeldRadios.hold(@mac, 0, opts) == :ok
    assert HeldRadios.release(@mac, opts) == :ok
    assert HeldRadios.list(opts) == []
    refute HeldRadios.held?(@mac, opts)
  end
end
