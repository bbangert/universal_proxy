defmodule UniversalProxy.Audio.ServerTest do
  # async: false — the test shares one named EnumerateStub Agent and
  # subscribes the test PID to global PubSub topics. Concurrent tests
  # would see each other's broadcasts.
  use ExUnit.Case, async: false

  alias UniversalProxy.Audio.{Server, Store}

  @pubsub UniversalProxy.PubSub
  @store_table :audio_server_store_test

  @hp_key {"bcm2835 Headphones", nil, nil}
  @hdmi_key {"vc4-hdmi", nil, nil}

  defmodule EnumerateStub do
    @moduledoc false
    use Agent

    def start_link(initial \\ %{}) do
      Agent.start_link(fn -> initial end, name: __MODULE__)
    end

    def set(outputs), do: Agent.update(__MODULE__, fn _ -> outputs end)

    @doc false
    def safe, do: Agent.get(__MODULE__, & &1)
  end

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "audio_server_test_#{System.unique_integer([:positive])}.dets"
      )

    on_exit(fn -> File.rm(path) end)

    start_supervised!({EnumerateStub, %{}})

    store =
      start_supervised!({Store, name: nil, table: @store_table, dets_path: path}, id: :store)

    server =
      start_supervised!(
        {Server, name: nil, store: store, enumerate_module: EnumerateStub, start_timer: false},
        id: :server
      )

    :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:output_added")
    :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:output_removed")
    :ok = Phoenix.PubSub.subscribe(@pubsub, "sendspin:state")

    {:ok, server: server, store: store}
  end

  describe "hotplug add" do
    test "broadcasts :sendspin_output_added and persists DETS row", %{
      server: server,
      store: store
    } do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Server.check_now(server)

      assert_receive {:sendspin_output_added, output}
      assert output.key == @hp_key
      assert output.alsa_device == "plughw:0,0"
      assert output.card_name == "bcm2835 Headphones"
      assert output.friendly_name == "bcm2835 Headphones"
      assert output.enabled == true
      assert output.volume == 50
      assert output.muted == false
      assert is_binary(output.client_id)

      assert {:ok, cfg} = Store.get_config(store, @hp_key)
      assert cfg.friendly_name == "bcm2835 Headphones"
      assert cfg.client_id == output.client_id
    end

    test "does not re-broadcast for outputs already known to the server", %{server: server} do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Server.check_now(server)
      assert_receive {:sendspin_output_added, _}

      :ok = Server.check_now(server)
      refute_receive {:sendspin_output_added, _}, 200
    end
  end

  describe "hotplug remove" do
    test "broadcasts :sendspin_output_removed but keeps the DETS row", %{
      server: server,
      store: store
    } do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Server.check_now(server)
      assert_receive {:sendspin_output_added, _}

      EnumerateStub.set(%{})
      :ok = Server.check_now(server)

      assert_receive {:sendspin_output_removed, %{key: @hp_key}}
      # DETS row survives unplug so user config sticks across reboot
      assert {:ok, %{friendly_name: "bcm2835 Headphones"}} = Store.get_config(store, @hp_key)
    end
  end

  describe "list_outputs/1 + get_output/2" do
    test "returns merged maps sorted by friendly_name", %{server: server} do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        },
        @hdmi_key => %{
          card_index: 1,
          alsa_device: "plughw:1,0",
          card_name: "vc4-hdmi"
        }
      })

      :ok = Server.check_now(server)
      # Two `:sendspin_output_added` messages arrive in any order
      # (refresh_outputs/1 iterates `MapSet.difference/2` which is
      # unordered). These two `assert_receive` calls drain the mailbox;
      # the actual ordering assertion lives in `list_outputs/1`, which
      # the Server sorts by friendly_name.
      assert_receive {:sendspin_output_added, _}
      assert_receive {:sendspin_output_added, _}

      [first, second] = Server.list_outputs(server)
      assert first.card_name == "bcm2835 Headphones"
      assert second.card_name == "vc4-hdmi"

      assert {:ok, hp} = Server.get_output(server, @hp_key)
      assert hp.card_name == "bcm2835 Headphones"

      assert :error = Server.get_output(server, {"nope", nil, nil})
    end
  end

  describe "update_config/3" do
    setup %{server: server} do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Server.check_now(server)
      assert_receive {:sendspin_output_added, _}
      :ok
    end

    test "persists allowed fields and broadcasts :sendspin_state", %{
      server: server,
      store: store
    } do
      :ok =
        Server.update_config(server, @hp_key, %{
          friendly_name: "Living Room",
          volume: 75,
          muted: true,
          # silently dropped
          enabled: false
        })

      assert_receive {:sendspin_state, @hp_key, partial}
      assert partial == %{friendly_name: "Living Room", volume: 75, muted: true}

      {:ok, persisted} = Store.get_config(store, @hp_key)
      assert persisted.friendly_name == "Living Room"
      assert persisted.volume == 75
      assert persisted.muted == true
      # :enabled NOT modified via update_config
      assert persisted.enabled == true
    end

    test "returns {:error, :not_found} for unknown output", %{server: server} do
      assert {:error, :not_found} =
               Server.update_config(server, {"missing", nil, nil}, %{friendly_name: "x"})
    end
  end

  describe "set_enabled/3" do
    test "persists, broadcasts, and survives in get_output/2", %{server: server, store: store} do
      EnumerateStub.set(%{
        @hp_key => %{
          card_index: 0,
          alsa_device: "plughw:0,0",
          card_name: "bcm2835 Headphones"
        }
      })

      :ok = Server.check_now(server)
      assert_receive {:sendspin_output_added, _}

      :ok = Server.set_enabled(server, @hp_key, false)

      assert_receive {:sendspin_state, @hp_key, %{enabled: false}}
      assert {:ok, %{enabled: false}} = Store.get_config(store, @hp_key)
      assert {:ok, %{enabled: false}} = Server.get_output(server, @hp_key)
    end
  end
end
