defmodule UniversalProxy.Bluez.GattTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Bluez.{DevicePath, Gatt}

  # The Gatt GenServer needs a live D-Bus connection (hardware-validated,
  # like Bluez.Client); the pair/remove RESULT handling is pure state +
  # subscriber messaging, so those handle_info clauses are exercised
  # directly here.

  @address 0xAABBCCDDEEFF
  @gen 7

  defp entry(subscriber, overrides \\ %{}) do
    Map.merge(
      %{
        path: DevicePath.from_address(@address),
        subscriber: subscriber,
        status: :ready,
        tree: nil,
        resolve_timer: nil,
        gen: @gen
      },
      overrides
    )
  end

  defp state(subscriber, overrides \\ %{}) do
    Map.merge(
      %{conns: %{@address => entry(subscriber)}, notify_paths: %{}, gen_seq: @gen},
      overrides
    )
  end

  describe "pair_result" do
    test "success reports paired with no error" do
      state = state(self())

      assert {:noreply, ^state} =
               Gatt.handle_info({:pair_result, @address, @gen, self(), :ok}, state)

      assert_receive {:espex_ble_pair, @address, true, 0}
    end

    test "failure forwards the error code" do
      state = state(self())

      assert {:noreply, ^state} =
               Gatt.handle_info({:pair_result, @address, @gen, self(), {:error, -1}}, state)

      assert_receive {:espex_ble_pair, @address, false, -1}
    end

    test "reply is delivered even when the entry is already gone" do
      # A failed Pair can drop the link; the Connected=false signal tears
      # the entry down before the pair Task's result arrives. The reply
      # must still reach the captured subscriber (hw-observed on H60B0).
      state = %{conns: %{}, notify_paths: %{}, gen_seq: @gen}

      assert {:noreply, ^state} =
               Gatt.handle_info({:pair_result, @address, @gen, self(), {:error, -1}}, state)

      assert_receive {:espex_ble_pair, @address, false, -1}
    end
  end

  describe "remove_result (unpair / clear_cache)" do
    test "success replies, then reports the disconnect, then drops the entry" do
      char_path = entry(self()).path <> "/service000a/char000b"

      state =
        state(self(), %{
          notify_paths: %{
            char_path => {@address, 12},
            "/org/bluez/hci0/dev_11_22_33_44_55_66/service0001/char0002" => {0x112233445566, 9}
          }
        })

      assert {:noreply, new_state} =
               Gatt.handle_info(
                 {:remove_result, @address, @gen, :espex_ble_unpair, self(), :ok},
                 state
               )

      # The op reply must land before the connection teardown envelope.
      assert {:messages,
              [
                {:espex_ble_unpair, @address, true, 0},
                {:espex_ble_connection, @address, {:error, -2}}
              ]} = Process.info(self(), :messages)

      # Entry gone; only this address's notification routes swept.
      assert new_state.conns == %{}

      assert Map.keys(new_state.notify_paths) == [
               "/org/bluez/hci0/dev_11_22_33_44_55_66/service0001/char0002"
             ]
    end

    test "clear_cache uses its own reply envelope" do
      state = state(self())

      assert {:noreply, new_state} =
               Gatt.handle_info(
                 {:remove_result, @address, @gen, :espex_ble_clear_cache, self(), :ok},
                 state
               )

      assert_receive {:espex_ble_clear_cache, @address, true, 0}
      assert_receive {:espex_ble_connection, @address, {:error, -2}}
      assert new_state.conns == %{}
    end

    test "failure keeps the entry and forwards the error" do
      state = state(self())

      assert {:noreply, ^state} =
               Gatt.handle_info(
                 {:remove_result, @address, @gen, :espex_ble_unpair, self(), {:error, -1}},
                 state
               )

      assert_receive {:espex_ble_unpair, @address, false, -1}
      refute_received {:espex_ble_connection, _, _}
    end

    test "success after the Connected=false signal already tore the entry down" do
      # BlueZ disconnects the device DURING RemoveDevice, before the method
      # returns — the signal path can drop the entry (and send its own
      # teardown envelope) first. The op reply must still be delivered, with
      # no duplicate teardown envelope (hw-observed on H60B0).
      state = %{conns: %{}, notify_paths: %{}, gen_seq: @gen}

      assert {:noreply, ^state} =
               Gatt.handle_info(
                 {:remove_result, @address, @gen, :espex_ble_clear_cache, self(), :ok},
                 state
               )

      assert_receive {:espex_ble_clear_cache, @address, true, 0}
      refute_received {:espex_ble_connection, _, _}
    end

    test "success for a replaced entry replies without touching the new entry" do
      # A new connect generation owns the address; the old op's reply goes
      # to its captured subscriber and the fresh entry stays intact.
      state = state(self())

      assert {:noreply, ^state} =
               Gatt.handle_info(
                 {:remove_result, @address, @gen - 1, :espex_ble_unpair, self(), :ok},
                 state
               )

      assert_receive {:espex_ble_unpair, @address, true, 0}
      refute_received {:espex_ble_connection, _, _}
      assert map_size(state.conns) == 1
    end
  end

  describe "pair/unpair/clear_cache casts for unknown addresses" do
    test "are dropped without crashing (no subscriber to answer)" do
      state = %{conns: %{}, notify_paths: %{}, gen_seq: 0}

      assert {:noreply, ^state} = Gatt.handle_cast({:pair, @address}, state)
      assert {:noreply, ^state} = Gatt.handle_cast({:unpair, @address}, state)
      assert {:noreply, ^state} = Gatt.handle_cast({:clear_cache, @address}, state)
    end
  end
end
