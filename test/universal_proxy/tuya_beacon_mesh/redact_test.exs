defmodule UniversalProxy.TuyaBeaconMesh.RedactTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaBeaconMesh.{Inventory, Redact}
  alias UniversalProxy.TuyaMesh.KeyLeak

  @beacon_key "00112233445566778899aabbccddeeff"
  @local_key "abcdefghijklmnop"

  describe "term/1" do
    test "drops inventories, bulbs, key-named fields in any style and key-shaped binaries" do
      inv = Inventory.decode!(KeyLeak.json())

      for t <- [
            inv,
            hd(inv.bulbs),
            Inventory.to_map(inv),
            KeyLeak.snake_map(),
            KeyLeak.json(),
            String.to_charlist(KeyLeak.json()),
            %{beaconKey: @beacon_key},
            %{"LOCAL-KEY" => @local_key},
            %{BeaconKey: @beacon_key},
            @beacon_key,
            String.upcase(@beacon_key),
            [:a | @beacon_key]
          ] do
        assert Redact.term(t) == :redacted, inspect(t)
      end
    end

    test "walks into containers and keeps what carries no key" do
      inv = Inventory.decode!(KeyLeak.json())
      term = {:ok, [%{label: "path light 2", inv: inv}, {:mac, "DC23530FB34A"}]}

      assert {:ok, [%{label: "path light 2", inv: :redacted}, {:mac, "DC23530FB34A"}]} =
               Redact.term(term)

      assert Redact.term(%ArgumentError{message: @beacon_key}) == {:exception, ArgumentError}
    end
  end

  describe "seal/1 and unseal/1" do
    test "a sealed term prints as a bare function in both printers" do
      sealed = Redact.seal(Inventory.decode!(KeyLeak.json()))

      KeyLeak.refute_keys({:state, sealed})
      assert %Inventory{beacon_key: @beacon_key} = Redact.unseal(sealed)
    end

    test "unseal leaves other terms and other functions alone, uncalled" do
      me = self()
      fun = fn -> send(me, :called) end

      assert Redact.unseal(fun) == fun
      refute_received :called
      assert Redact.unseal(:plain) == :plain
    end
  end

  describe "format_status/2" do
    test "redacts tagged requests by position and everything else by shape" do
      call = {:"$gen_call", {self(), make_ref()}, {:reload, "anything"}}

      status =
        Redact.format_status(
          %{
            state: %{keys: Redact.seal(@local_key), inventory: %{beacon_key: @beacon_key}},
            message: call,
            queue: [call, {:"$gen_cast", {:reload, @local_key}}],
            log: [{:in, {:reload, "x"}, self()}, {:out, {:ok, KeyLeak.snake_map()}, self(), %{}}],
            reason: {:function_clause, [{Mod, :fun, [@beacon_key, @local_key], [line: 1]}]}
          },
          [:reload]
        )

      KeyLeak.refute_keys(status)
      assert {:"$gen_call", _, {:reload, :redacted}} = status.message
      assert [_, {:"$gen_cast", {:reload, :redacted}}] = status.queue
      assert [{:in, {:reload, :redacted}, _}, {:out, {:ok, :redacted}, _, %{}}] = status.log
      assert {:function_clause, [{Mod, :fun, 2, [line: 1]}]} = status.reason
      assert %{inventory: :redacted} = status.state
    end
  end

  describe "guard/2" do
    test "re-raises anything as a key-free error with arity-only frames" do
      inv = Inventory.decode!(KeyLeak.json())

      for body <- [
            fn -> raise ArgumentError, "bad " <> @beacon_key end,
            fn -> :erlang.error(:badarg, [inv]) end,
            fn -> throw(inv) end,
            fn -> exit({:bad, inv}) end,
            fn -> elem({@local_key}, Process.get(:no_such_index, 5)) end
          ] do
        {error, stack} =
          try do
            Redact.guard("label", body)
          rescue
            e -> {e, __STACKTRACE__}
          end

        assert %Redact.Error{message: "label: " <> _} = error
        assert Enum.all?(stack, &is_integer(elem(&1, 2)))
        KeyLeak.refute_keys({error, stack})
      end
    end

    test "returns the body's value" do
      assert Redact.guard("label", fn -> {:reply, :ok, :state} end) == {:reply, :ok, :state}
    end
  end
end
