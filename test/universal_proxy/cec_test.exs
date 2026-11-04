defmodule UniversalProxy.CecTest do
  # async: false - uses the subtree's fixed registry name.
  use ExUnit.Case, async: false

  alias UniversalProxy.Cec
  alias UniversalProxy.Cec.Supervisor

  @dev "/dev/cec0"

  describe "with the subsystem off" do
    test "every call degrades to a harmless default" do
      refute Cec.available?()
      assert Cec.list_adapters() == []
      assert Cec.get_adapter(@dev) == :error
      assert Cec.info(@dev) == {:error, :cec_unavailable}
      assert Cec.one_touch_play(@dev) == {:error, :cec_unavailable}
      assert Cec.standby(@dev) == {:error, :cec_unavailable}
      assert Cec.power_status(@dev) == {:error, :cec_unavailable}
      assert Cec.audio_status(@dev) == {:error, :cec_unavailable}
      assert Cec.volume_up(@dev) == {:error, :cec_unavailable}
    end
  end

  test "auto_wake?/2: the output's setting wins, else the default" do
    assert Cec.auto_wake?(%{cec_auto_wake: false}, true) == false
    assert Cec.auto_wake?(%{cec_auto_wake: true}, false) == true
    assert Cec.auto_wake?(%{cec_auto_wake: nil}, false) == false
    assert Cec.auto_wake?(%{}, true) == true
    # The env default (config.exs: auto_wake: true).
    assert Cec.auto_wake?(%{}) == true
  end

  describe "with an adapter that doesn't answer" do
    setup do
      start_supervised!({Registry, keys: :unique, name: Supervisor.registry()})
      :ok
    end

    test "a wedged adapter is a timeout, not CEC off" do
      register_adapter(fn -> Process.sleep(:infinity) end)
      assert Cec.power_status(@dev, call_timeout: 50) == {:error, :timeout}
      assert Cec.one_touch_play(@dev, call_timeout: 50) == {:error, :timeout}
    end

    test "an adapter that stops mid-call is CEC off" do
      register_adapter(fn ->
        receive do
          {:"$gen_call", _from, _request} -> exit(:normal)
        end
      end)

      assert Cec.power_status(@dev) == {:error, :cec_unavailable}
    end

    test "an unknown device is no_such_adapter" do
      assert Cec.power_status("/dev/cec9") == {:error, :no_such_adapter}
    end
  end

  test "call_adapter/1 only converts call-shaped exits" do
    assert Cec.call_adapter(fn -> :ok end) == :ok

    assert Cec.call_adapter(fn -> exit({:timeout, {GenServer, :call, []}}) end) ==
             {:error, :timeout}

    assert Cec.call_adapter(fn -> exit({:noproc, {GenServer, :call, []}}) end) ==
             {:error, :cec_unavailable}

    assert catch_exit(Cec.call_adapter(fn -> exit(:boom) end)) == :boom
  end

  defp register_adapter(loop) do
    test = self()

    pid =
      spawn_link(fn ->
        {:ok, _} = Registry.register(Supervisor.registry(), @dev, nil)
        send(test, :registered)
        loop.()
      end)

    assert_receive :registered
    pid
  end
end
