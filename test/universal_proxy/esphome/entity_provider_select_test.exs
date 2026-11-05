defmodule UniversalProxy.ESPHome.EntityProviderSelectTest do
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Espex.Proto
  alias UniversalProxy.Display.Mode
  alias UniversalProxy.ESPHome.EntityProvider, as: EP

  @object_id "tv_display_mode"

  defp key, do: EP.key_for(@object_id)

  defp sources(overrides) do
    Map.merge(
      %{
        metrics: fn -> %{} end,
        wifi: fn -> nil end,
        network_type: fn -> :ethernet end,
        firmware: fn -> %{version: "1.2.3", target: "rpi3"} end,
        ip: fn -> "192.168.1.50" end,
        clients_count: fn -> 1 end,
        audio: fn -> [] end,
        storage: fn -> %{drives: [], mount: nil, share: :off, capacity: nil} end,
        bt_stats: fn -> %{} end,
        adapters: fn -> [] end,
        fw_update: fn -> {:error, :unavailable} end,
        fw_version: fn -> "1.2.3" end,
        fw_repo: fn -> nil end,
        fw_check: fn -> :ok end,
        fw_install: fn -> :ok end,
        fw_alive: fn -> true end,
        display_mode: fn -> :now_playing end,
        display_set_mode: fn _option -> :ok end
      },
      overrides
    )
  end

  describe "advertisement" do
    test "only while the TV UI is on" do
      for supported? <- [true, false] do
        ids = Enum.map(EP.advertisements(EP.specs(), supported?), & &1.object_id)
        refute @object_id in ids

        ids = Enum.map(EP.advertisements(EP.specs(), supported?, true), & &1.object_id)
        assert @object_id in ids
      end
    end

    test "is a primary-control select with the frozen options" do
      ad =
        EP.specs() |> EP.advertisements(false, true) |> Enum.find(&(&1.object_id == @object_id))

      assert %Proto.ListEntitiesSelectResponse{
               key: key,
               name: "TV display mode",
               options: ["Now Playing", "Visualizer", "Party QR", "Off"],
               entity_category: :ENTITY_CATEGORY_NONE,
               icon: "mdi:television",
               disabled_by_default: false
             } = ad

      assert key == key()
      assert ad.options == Mode.options()
    end

    test "is not a privileged entity" do
      assert EP.privileged_object_id(%Proto.SelectCommandRequest{key: key(), state: "Off"}) ==
               nil
    end
  end

  describe "state responses" do
    test "the option, or missing while the display is down" do
      [state] =
        EP.specs()
        |> EP.state_responses(%{@object_id => "Visualizer"}, false, true)
        |> Enum.filter(&(&1.key == key()))

      assert %Proto.SelectStateResponse{state: "Visualizer", missing_state: false} = state

      [state] =
        EP.specs()
        |> EP.state_responses(%{}, false, true)
        |> Enum.filter(&(&1.key == key()))

      assert %Proto.SelectStateResponse{state: "", missing_state: true} = state
    end

    test "none while the TV UI is off" do
      responses = EP.state_responses(EP.specs(), %{@object_id => "Off"}, false)
      refute Enum.any?(responses, &(&1.key == key()))
    end
  end

  describe "provider" do
    setup do
      server = :"ep_select_#{System.unique_integer([:positive])}"
      registry = Module.concat(server, "Registry")
      start_supervised!({Registry, keys: :duplicate, name: registry})
      {:ok, _} = Registry.register(registry, :subscribers, nil)

      pubsub = :"ep_select_pubsub_#{System.unique_integer([:positive])}"
      start_supervised!({Phoenix.PubSub, name: pubsub})

      mode = start_supervised!({Agent, fn -> :now_playing end})
      %{server: server, pubsub: pubsub, mode: mode}
    end

    defp start_provider(ctx, opts \\ []) do
      test = self()
      mode = ctx.mode

      sources =
        sources(%{
          display_mode: fn -> Agent.get(mode, & &1) end,
          display_set_mode: fn option ->
            send(test, {:set_mode, option})
            {:ok, parsed} = Mode.parse(option)
            Agent.update(mode, fn _ -> parsed end)
            :ok
          end
        })

      pid =
        start_supervised!(
          {EP,
           Keyword.merge(
             [
               name: :"ep_select_proc_#{System.unique_integer([:positive])}",
               server: ctx.server,
               pubsub: ctx.pubsub,
               poll: false,
               supported?: false,
               display?: true,
               sources: Map.to_list(sources)
             ],
             opts
           )}
        )

      GenServer.call(pid, :poll_now)
      drain()
      pid
    end

    defp drain do
      receive do
        {:espex_state_update, _} -> drain()
      after
        0 -> :ok
      end
    end

    defp command(pid, option) do
      GenServer.cast(pid, {:command, %Proto.SelectCommandRequest{key: key(), state: option}})
      _ = :sys.get_state(pid)
    end

    test "lists the select and reports the current mode", ctx do
      pid = start_provider(ctx)
      assert Enum.any?(GenServer.call(pid, :list_entities), &(&1.object_id == @object_id))

      assert %Proto.SelectStateResponse{state: "Now Playing"} =
               pid |> GenServer.call(:initial_states) |> Enum.find(&(&1.key == key()))
    end

    test "a valid option sets the mode and echoes the new state", ctx do
      pid = start_provider(ctx)
      command(pid, "Visualizer")

      assert_receive {:set_mode, "Visualizer"}
      assert_receive {:espex_state_update, %Proto.SelectStateResponse{state: "Visualizer"}}
    end

    test "an option outside the frozen list is rejected", ctx do
      pid = start_provider(ctx)

      for bad <- ["visualizer", "Off ", "", "Party"] do
        command(pid, bad)
      end

      refute_received {:set_mode, _}
      refute_received {:espex_state_update, _}
    end

    test "a failed set leaves HA on the real mode", ctx do
      test = self()

      pid =
        start_provider(ctx,
          sources:
            Map.to_list(
              sources(%{
                display_mode: fn -> :off end,
                display_set_mode: fn option ->
                  send(test, {:set_mode, option})
                  {:error, :not_running}
                end
              })
            )
        )

      command(pid, "Visualizer")
      assert_receive {:set_mode, "Visualizer"}
      refute_received {:espex_state_update, _}
      assert %{"tv_display_mode" => "Off"} = GenServer.call(pid, :poll_now)
    end

    test "is ignored while the TV UI is off", ctx do
      pid = start_provider(ctx, display?: false)
      refute Enum.any?(GenServer.call(pid, :list_entities), &(&1.object_id == @object_id))
      command(pid, "Off")
      refute_received {:set_mode, _}
    end

    test "a display mode broadcast pushes the select at once, once", ctx do
      pid = start_provider(ctx, subscribe: true)

      Phoenix.PubSub.broadcast(ctx.pubsub, "display:state", {:display_mode, :off})
      _ = :sys.get_state(pid)
      assert_receive {:espex_state_update, %Proto.SelectStateResponse{state: "Off"} = pushed}
      assert pushed.key == key()

      Phoenix.PubSub.broadcast(ctx.pubsub, "display:state", {:display_mode, :off})
      _ = :sys.get_state(pid)
      refute_received {:espex_state_update, _}
    end
  end
end
