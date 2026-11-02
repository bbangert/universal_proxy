defmodule UniversalProxy.TuyaBeaconMesh.RedactTest do
  use ExUnit.Case, async: true

  defmodule Foreign do
    @moduledoc false
    def closure(pid), do: fn -> send(pid, :foreign) end
    def notify, do: send(self(), :foreign)
  end

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

  describe "term/1 through containers" do
    defmodule Holder do
      @moduledoc false
      defstruct [:label, :payload]
    end

    test "a MapSet, a struct field, a map key and deep nesting hold no key afterwards" do
      inv = Inventory.decode!(KeyLeak.json())

      cases = [
        MapSet.new([inv, "kept"]),
        MapSet.new([{:dump, KeyLeak.json()}]),
        %Holder{label: "lamp", payload: inv},
        %Holder{label: "lamp", payload: %{nested: [MapSet.new([KeyLeak.snake_map()])]}},
        %{inv => :value},
        %{{:k, @beacon_key} => 1, [hd(inv.bulbs)] => 2},
        {:a, [b: {:c, [%{d: [inv]}]}]},
        [{:ok, [MapSet.new([%Holder{payload: {"x", inv}}])]}],
        Enum.reduce(1..10, inv, &{&1, [&2]})
      ]

      for t <- cases do
        KeyLeak.refute_keys(Redact.term(t))
      end
    end

    test "keeps what it needn't change and marks a changed struct" do
      inv = Inventory.decode!(KeyLeak.json())
      plain = [1..3, ~r/x/, ~D[2026-11-02], DateTime.from_unix!(0), %Holder{label: "lamp"}]

      assert Redact.term(plain) == plain
      assert Redact.term(MapSet.new([inv, "kept"])) == MapSet.new([:redacted, "kept"])

      assert Redact.term(%Holder{label: "lamp", payload: inv}) ==
               {:struct, Holder, %{label: "lamp", payload: :redacted}}

      assert Redact.term(%{inv => :value}) == %{redacted: :value}
    end

    test "is bounded: anything nested past the depth limit is redacted whole" do
      deep = Enum.reduce(1..100, "leaf", &{&1, &2})
      assert Redact.term(deep) |> inspect(limit: :infinity) =~ ":redacted"
      refute Redact.term(deep) |> inspect(limit: :infinity) =~ "leaf"
      assert Redact.term(Enum.reduce(1..10, "leaf", &{&1, &2})) |> inspect() =~ "leaf"
    end

    test "format_status/2 walks containers in requests" do
      inv = Inventory.decode!(KeyLeak.json())
      call = {:"$gen_call", {self(), make_ref()}, {:other, MapSet.new([inv])}}

      status =
        Redact.format_status(%{message: call, queue: [call], state: %{s: MapSet.new([inv])}})

      KeyLeak.refute_keys(status)
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

      for fun <- [
            # A local closure from another module.
            fn -> send(me, :called) end,
            # Another module's closure.
            Foreign.closure(me),
            # External zero-arity captures naming Redact: one that exists
            # (it would return the module info) and one that doesn't.
            &Redact.module_info/0,
            Function.capture(Redact, :no_such_fun, 0),
            # Another module's external capture.
            &Foreign.notify/0
          ] do
        assert Redact.unseal(fun) == fun
      end

      refute_received :called
      refute_received :foreign
      assert Redact.unseal(:plain) == :plain
      assert Redact.unseal(Redact.seal(:inside)) == :inside
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
