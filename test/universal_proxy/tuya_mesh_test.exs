defmodule UniversalProxy.TuyaMeshTest do
  # The no-Resolver path broadcasts on the app's PubSub topic.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.TuyaMesh
  alias UniversalProxy.TuyaMesh.Store

  @moduletag :tmp_dir

  @fixture Path.join([
             __DIR__,
             "..",
             "fixtures",
             "tuya_beacon_mesh",
             "example_inventory.json"
           ])

  @beacon_key "00112233445566778899aabbccddeeff"
  @other_key "ffeeddccbbaa99887766554433221100"
  @local_keys ["abcdefghijklmnop", "ponmlkjihgfedcba"]

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])

    store =
      start_supervised!(
        {Store,
         name: nil,
         enabled: true,
         table: :"tuya_facade_#{n}",
         dets_path: Path.join(tmp_dir, "f.dets")}
      )

    # No Resolver runs under this name unless a test starts one.
    opts = [store: store, resolver: :"tuya_facade_resolver_#{n}"]
    {:ok, store: store, opts: opts, n: n}
  end

  defp json(overrides \\ %{}) do
    @fixture |> File.read!() |> Jason.decode!() |> Map.merge(overrides) |> Jason.encode!()
  end

  defp refute_secrets(term) do
    text = if is_binary(term), do: term, else: inspect(term, limit: :infinity)

    for secret <- [@beacon_key, @other_key | @local_keys] do
      refute text =~ secret
      refute text =~ String.upcase(secret)
    end
  end

  describe "upload without a running mesh" do
    test "stores the dump and broadcasts the new status", ctx do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, TuyaMesh.topic())

      assert {:ok, :new_mesh} = TuyaMesh.upload(json(), ctx.opts)
      assert {:ok, %{seq: 100}} = Store.load(ctx.store)

      assert_receive {:tuya_mesh_status,
                      %{state: :idle, reason: :no_role, bulbs: [_, _]} = status}

      refute_secrets(status)
    end

    test "the same mesh again goes through and keeps the cursor", ctx do
      {:ok, _} = TuyaMesh.upload(json(%{"seq" => 500}), ctx.opts)
      assert {:ok, :same_mesh} = TuyaMesh.upload(json(), ctx.opts)
      assert {:ok, %{seq: 500}} = Store.load(ctx.store)
    end

    test "a different mesh needs confirmation, with a diff", ctx do
      {:ok, _} = TuyaMesh.upload(json(), ctx.opts)
      other = json(%{"beaconKey" => @other_key, "seq" => 3})

      assert {:error, {:confirm_new_mesh, preview}} = TuyaMesh.upload(other, ctx.opts)
      assert preview.mesh == :new_mesh
      refute_secrets(preview)
      assert {:ok, %{seq: 100, beacon_key: @beacon_key}} = Store.load(ctx.store)

      assert {:ok, :new_mesh} = TuyaMesh.upload(other, [confirm: true] ++ ctx.opts)
      assert {:ok, %{seq: 3, beacon_key: @other_key}} = Store.load(ctx.store)
    end

    test "preview reports without writing", ctx do
      [b2, _b3] = json() |> Jason.decode!() |> Map.fetch!("bulbs")

      assert {:ok, %{mesh: :empty, bulbs: %{added: [_, _], removed: []}}} =
               TuyaMesh.preview(json(), ctx.opts)

      {:ok, _} = TuyaMesh.upload(json(), ctx.opts)

      assert {:ok, %{mesh: :same_mesh, bulbs: %{added: [], removed: [%{label: "post spot 1"}]}}} =
               TuyaMesh.preview(json(%{"bulbs" => [b2], "groups" => []}), ctx.opts)

      assert {:ok, %{bulbs: [_, _]}} = Store.load(ctx.store)
    end
  end

  describe "bad input" do
    test "malformed JSON: a redacted error, nothing logged with keys", ctx do
      truncated = binary_part(json(), 0, 120)
      assert truncated =~ @beacon_key

      log =
        capture_log(fn ->
          assert {:error, {:invalid_inventory, {:invalid_json, _pos}}} =
                   error = TuyaMesh.upload(truncated, ctx.opts)

          refute_secrets(error)
        end)

      refute_secrets(log)
      assert Store.load(ctx.store) == {:error, :no_inventory}
    end

    test "an invalid key: the error names the bulb, never the keys", ctx do
      raw = json() |> Jason.decode!()

      bad =
        Map.update!(raw, "bulbs", fn [b | rest] ->
          [Map.put(b, "localKey", "not-a-key-" <> @other_key) | rest]
        end)

      log =
        capture_log(fn ->
          assert {:error, {:invalid_inventory, {:bad_local_key, "DC23530FB34A"}}} =
                   error = TuyaMesh.upload(Jason.encode!(bad), ctx.opts)

          refute_secrets(error)

          assert {:error, {:invalid_inventory, _}} =
                   TuyaMesh.preview(Jason.encode!(bad), ctx.opts)
        end)

      refute_secrets(log)
    end
  end

  describe "status and clear without a running mesh" do
    test "status is store-backed and key-free", ctx do
      assert %{state: :idle, reason: :no_role, bulbs: [], radio: nil} = TuyaMesh.status(ctx.opts)
      {:ok, _} = TuyaMesh.upload(json(), ctx.opts)

      assert %{bulbs: [%{mac: "DC23530FB34A", node_id: 2, reachable: false, last_seen: nil}, _]} =
               status = TuyaMesh.status(ctx.opts)

      refute_secrets(status)
    end

    test "clear removes the inventory", ctx do
      {:ok, _} = TuyaMesh.upload(json(), ctx.opts)
      assert :ok = TuyaMesh.clear(ctx.opts)
      assert %{bulbs: []} = TuyaMesh.status(ctx.opts)
    end

    test "settings pass through to the store", ctx do
      assert %{min_mireds: 154} = TuyaMesh.settings(ctx.opts)
      assert :ok = TuyaMesh.put_settings(%{min_mireds: 200}, ctx.opts)
      assert %{min_mireds: 200} = TuyaMesh.settings(ctx.opts)
    end

    test "everything degrades when the store is down too", ctx do
      down = [store: :"no_store_#{ctx.n}", resolver: :"no_resolver_#{ctx.n}"]
      assert {:error, :unavailable} = TuyaMesh.upload(json(), down)
      assert {:error, :unavailable} = TuyaMesh.preview(json(), down)
      assert {:error, :unavailable} = TuyaMesh.clear(down)
      assert %{state: :idle, bulbs: []} = TuyaMesh.status(down)
      assert TuyaMesh.settings(down) == Store.default_settings()
    end
  end

  describe "with a running mesh subtree" do
    setup ctx do
      adapters = [
        %{path: "/org/bluez/hci1", address: "AA:BB:CC:DD:EE:01", name: nil, powered: true},
        %{path: "/org/bluez/hci0", address: "AA:BB:CC:DD:EE:02", name: nil, powered: true}
      ]

      dynsup = :"tuya_facade_dynsup_#{ctx.n}"

      start_supervised!(
        {UniversalProxy.TuyaMesh.Supervisor,
         name: :"tuya_facade_sup_#{ctx.n}",
         dynsup: dynsup,
         resolver: ctx.opts[:resolver],
         tuya_adapter: "AA:BB:CC:DD:EE:01",
         store: ctx.store,
         adapters_fun: fn -> adapters end,
         mesh_spec_fun: fn index ->
           %{id: :mesh, start: {Agent, :start_link, [fn -> index end]}, restart: :temporary}
         end,
         radio: :"no_radio_#{ctx.n}",
         lights: :"no_lights_#{ctx.n}"}
      )

      {:ok, dynsup: dynsup}
    end

    test "upload starts the mesh; a re-upload restarts it; clear stops it", ctx do
      assert %{state: :idle, reason: :no_inventory} = TuyaMesh.status(ctx.opts)

      assert {:ok, :new_mesh} = TuyaMesh.upload(json(), ctx.opts)
      assert [{_, first, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
      assert %{state: :running, adapter_index: 1} = TuyaMesh.status(ctx.opts)

      assert {:ok, :same_mesh} = TuyaMesh.upload(json(), ctx.opts)
      assert [{_, second, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)
      assert second != first

      # An unconfirmed new mesh leaves the running mesh alone.
      assert {:error, {:confirm_new_mesh, _}} =
               TuyaMesh.upload(json(%{"beaconKey" => @other_key}), ctx.opts)

      assert [{_, ^second, _, _}] = DynamicSupervisor.which_children(ctx.dynsup)

      assert :ok = TuyaMesh.clear(ctx.opts)
      assert DynamicSupervisor.which_children(ctx.dynsup) == []
      assert %{state: :idle, reason: :no_inventory} = TuyaMesh.status(ctx.opts)
    end
  end
end
