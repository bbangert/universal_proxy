defmodule UniversalProxyWeb.TuyaMeshComponentTest do
  @moduledoc """
  The Tuya mesh card on the Bluetooth tab, against a real
  `UniversalProxy.TuyaMesh.Store` (tmp DETS, under its global name, which
  the host leaves free) and a real `Bluetooth.Settings` holding the role.
  No Resolver runs on the host, so the facade writes the Store directly and
  broadcasts the offline status, as when the mesh subtree is down.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias UniversalProxy.Bluetooth.Settings
  alias UniversalProxy.TuyaMesh
  alias UniversalProxy.TuyaMesh.{KeyLeak, Store}

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub

  @mesh_mac "AA:BB:CC:DD:EE:01"
  @other_key "ffeeddccbbaa99887766554433221100"
  @new_local_key "qrstuvwxyzabcdef"

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    n = System.unique_integer([:positive])

    start_supervised!(
      {Settings, table: :"tuya_ui_settings_#{n}", dets_path: Path.join(tmp_dir, "bt.dets")}
    )

    store =
      start_supervised!(
        {Store,
         enabled: true, table: :"tuya_ui_store_#{n}", dets_path: Path.join(tmp_dir, "mesh.dets")}
      )

    {:ok, conn: build_conn(), store: store}
  end

  defp assign_role, do: :ok = Settings.set_role(@mesh_mac, :tuya_mesh)

  defp mount_tab(conn) do
    {:ok, view, _html} = live(conn, "/bluetooth")
    view
  end

  defp json(overrides),
    do: KeyLeak.json() |> Jason.decode!() |> Map.merge(overrides) |> Jason.encode!()

  defp dump_entry(content, overrides \\ %{}) do
    Map.merge(
      %{name: "mesh.json", content: content, size: byte_size(content), type: "application/json"},
      overrides
    )
  end

  defp select_file(view, entry) do
    input = file_input(view, "#tuya-mesh-upload", :inventory, [entry])
    {input, render_upload(input, entry.name)}
  end

  defp submit_upload(view, content) do
    {_input, _} = select_file(view, dump_entry(content))
    view |> form("#tuya-mesh-upload") |> render_submit()
  end

  # The parent forwards a broadcast with send_update/3, a message to itself
  # queued behind the first render call: the second render sees it.
  defp push_status(view, status) do
    Phoenix.PubSub.broadcast(@pubsub, TuyaMesh.topic(), {:tuya_mesh_status, status})
    _ = render(view)
    render(view)
  end

  defp confirm_token(view) do
    [token] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("button[phx-click=confirm_upload]")
      |> LazyHTML.attribute("phx-value-token")

    token
  end

  defp refute_secrets(html) do
    KeyLeak.refute_keys(html)
    refute html =~ @other_key
    refute html =~ @new_local_key
  end

  # A dump of another mesh: bulb "post spot 1" replaced by a new one, no groups.
  defp other_mesh_json do
    [b2, _b3] = KeyLeak.json() |> Jason.decode!() |> Map.fetch!("bulbs")

    new_bulb = %{
      "mac" => "DC2353000001",
      "localKey" => @new_local_key,
      "nodeId" => 9,
      "label" => "porch"
    }

    json(%{"beaconKey" => @other_key, "seq" => 3, "bulbs" => [b2, new_bulb], "groups" => []})
  end

  test "hidden without a Tuya mesh role", %{conn: conn} do
    view = mount_tab(conn)
    refute has_element?(view, "#tuya-mesh")
  end

  describe "with a Tuya mesh role" do
    setup do
      assign_role()
      :ok
    end

    test "shown, with the help text", %{conn: conn} do
      view = mount_tab(conn)
      assert has_element?(view, "#tuya-mesh")
      html = render(view)
      # No Resolver on the host: the facade's offline status.
      assert html =~ "Idle"
      assert html =~ "The mesh service isn&#39;t running."
      assert html =~ "0600"
      assert html =~ "upload a fresh dump"
      assert html =~ "The mesh radio is dedicated"

      # The file picker has an accessible name.
      assert has_element?(view, ~s(input[type="file"][aria-label="Tuya mesh JSON key dump"]))

      idle = %{TuyaMesh.status() | reason: :no_inventory}
      html = push_status(view, idle)
      assert html =~ "Not set up"
      assert html =~ "Upload your mesh&#39;s JSON dump to start."
      refute has_element?(view, "button[phx-click=ask_clear]")
    end

    test "a valid upload into an empty store succeeds and lists the bulbs", %{conn: conn} = ctx do
      view = mount_tab(conn)
      html = submit_upload(view, KeyLeak.json())

      assert html =~ "Inventory uploaded."
      assert html =~ "Bulb added: <strong>path light 2</strong>"
      assert {:ok, %{seq: 100}} = Store.load(ctx.store)

      html = render(view)
      assert html =~ "path light 2"
      assert html =~ "DC23530FB34A · node 2"
      assert html =~ "post spot 1"
      assert html =~ "Never seen"
      assert html =~ "Not reachable"
      assert html =~ "path and post"
      assert html =~ "2 bulbs"
      assert html =~ "Clear inventory"
      refute_secrets(html)
    end

    test "a same-mesh upload that only adds bulbs or changes groups goes straight through",
         %{conn: conn} = ctx do
      [b2, _b3] = KeyLeak.json() |> Jason.decode!() |> Map.fetch!("bulbs")
      {:ok, _} = TuyaMesh.upload(json(%{"bulbs" => [b2], "groups" => []}))
      view = mount_tab(conn)

      html = submit_upload(view, KeyLeak.json())
      refute html =~ "Remove 1 bulb?"
      assert html =~ "Inventory updated (same mesh)."
      assert html =~ "Bulb added: <strong>post spot 1</strong>"
      assert html =~ "Group added: <strong>path and post</strong>"
      assert {:ok, %{bulbs: [_, _], groups: [_]}} = Store.load(ctx.store)

      html = submit_upload(view, json(%{"groups" => []}))
      assert html =~ "Group removed: <strong>path and post</strong>"
      assert {:ok, %{bulbs: [_, _], groups: []}} = Store.load(ctx.store)
      refute_secrets(render(view))
    end

    test "a same-mesh upload that removes a bulb asks first; confirm uploads it",
         %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)

      [b2, _b3] = KeyLeak.json() |> Jason.decode!() |> Map.fetch!("bulbs")
      html = submit_upload(view, json(%{"bulbs" => [b2], "groups" => []}))

      assert html =~ "Remove 1 bulb?"
      assert html =~ "leaves out"
      assert html =~ "drops the"
      assert html =~ "Bulb removed: <strong>post spot 1</strong>"
      assert html =~ "Group removed: <strong>path and post</strong>"
      refute html =~ "Replace the stored mesh?"
      refute_secrets(html)
      assert {:ok, %{bulbs: [_, _]}} = Store.load(ctx.store)

      html = view |> element("button[phx-click=confirm_upload]") |> render_click()
      refute html =~ "Remove 1 bulb?"
      assert html =~ "Inventory updated (same mesh)."
      assert {:ok, %{bulbs: [_], seq: 100}} = Store.load(ctx.store)
      refute_secrets(render(view))
    end

    test "cancelling a same-mesh bulb removal leaves the store alone", %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)

      [b2, _b3] = KeyLeak.json() |> Jason.decode!() |> Map.fetch!("bulbs")
      assert submit_upload(view, json(%{"bulbs" => [b2], "groups" => []})) =~ "Remove 1 bulb?"

      html = view |> element("button[phx-click=cancel_upload]") |> render_click()
      refute html =~ "Remove 1 bulb?"
      assert {:ok, %{bulbs: [_, _], groups: [_]}} = Store.load(ctx.store)
    end

    test "an identical re-upload says nothing changed", %{conn: conn} do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)

      assert submit_upload(view, KeyLeak.json()) =~ "No bulbs or groups were added or removed."
    end

    test "a new mesh asks first; confirm uploads it", %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)

      html = submit_upload(view, other_mesh_json())
      assert html =~ "Replace the stored mesh?"
      assert html =~ "different mesh"
      assert html =~ "drops the"
      assert html =~ "Bulb added: <strong>porch</strong>"
      assert html =~ "DC2353000001"
      assert html =~ "Bulb removed: <strong>post spot 1</strong>"
      assert html =~ "Group removed: <strong>path and post</strong>"
      refute_secrets(html)

      # Nothing written yet.
      assert {:ok, %{seq: 100, beacon_key: "00112233" <> _}} = Store.load(ctx.store)

      html = view |> element("button[phx-click=confirm_upload]") |> render_click()
      refute html =~ "Replace the stored mesh?"
      assert html =~ "New mesh uploaded."
      assert {:ok, %{seq: 3, beacon_key: @other_key}} = Store.load(ctx.store)
      assert render(view) =~ "porch"
      refute_secrets(render(view))
    end

    test "a new-mesh confirm over a store changed meanwhile re-asks with the fresh diff",
         %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)
      assert submit_upload(view, other_mesh_json()) =~ "Replace the stored mesh?"

      # Another tab stores a third mesh, without "path light 2".
      [_b2, b3] = KeyLeak.json() |> Jason.decode!() |> Map.fetch!("bulbs")
      third = json(%{"beaconKey" => String.duplicate("ab", 16), "bulbs" => [b3], "groups" => []})
      {:ok, :new_mesh} = TuyaMesh.upload(third, confirm: true)

      html = view |> element("button[phx-click=confirm_upload]") |> render_click()
      assert html =~ "Replace the stored mesh?"
      assert html =~ "The stored inventory changed since you chose this file."
      assert html =~ "Bulb added: <strong>path light 2</strong>"
      assert html =~ "Bulb removed: <strong>post spot 1</strong>"
      refute html =~ "Group removed"
      refute_secrets(html)
      assert {:ok, %{bulbs: [%{label: "post spot 1"}]}} = Store.load(ctx.store)

      html = view |> element("button[phx-click=confirm_upload]") |> render_click()
      assert html =~ "New mesh uploaded."
      assert {:ok, %{beacon_key: @other_key}} = Store.load(ctx.store)
    end

    test "a bulb-removal confirm over bulbs added meanwhile re-asks", %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)

      [b2, b3] = KeyLeak.json() |> Jason.decode!() |> Map.fetch!("bulbs")
      assert submit_upload(view, json(%{"bulbs" => [b2], "groups" => []})) =~ "Remove 1 bulb?"

      # Another tab adds a bulb to the same mesh.
      porch = %{
        "mac" => "DC2353000001",
        "localKey" => @new_local_key,
        "nodeId" => 9,
        "label" => "porch"
      }

      {:ok, :same_mesh} = TuyaMesh.upload(json(%{"bulbs" => [b2, b3, porch]}))

      html = view |> element("button[phx-click=confirm_upload]") |> render_click()
      assert html =~ "Remove 2 bulbs?"
      assert html =~ "The stored inventory changed since you chose this file."
      assert html =~ "Bulb removed: <strong>porch</strong>"
      refute_secrets(html)
      assert {:ok, %{bulbs: [_, _, _]}} = Store.load(ctx.store)

      html = view |> element("button[phx-click=cancel_upload]") |> render_click()
      refute html =~ "Remove 2 bulbs?"
      assert {:ok, %{bulbs: [_, _, _]}} = Store.load(ctx.store)
    end

    test "a confirm queued from a dialog that went stale can't confirm its replacement",
         %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)
      assert submit_upload(view, other_mesh_json()) =~ "Replace the stored mesh?"
      old = confirm_token(view)

      third = json(%{"beaconKey" => String.duplicate("ab", 16), "seq" => 9})
      {:ok, :new_mesh} = TuyaMesh.upload(third, confirm: true)

      # A double-click: both clicks carry the first dialog's token. The first
      # goes stale and opens a fresh dialog; the second must not confirm it.
      target = with_target(view, "#tuya-mesh")

      assert render_click(target, "confirm_upload", %{"token" => old}) =~
               "changed since you chose"

      fresh = confirm_token(view)
      assert fresh != old

      html = render_click(target, "confirm_upload", %{"token" => old})
      assert html =~ "Replace the stored mesh?"
      assert html =~ "changed since you chose"
      assert confirm_token(view) == fresh
      assert {:ok, %{seq: 9}} = Store.load(ctx.store)

      # The fresh dialog's own button still works.
      assert render_click(target, "confirm_upload", %{"token" => fresh}) =~ "New mesh uploaded."
      assert {:ok, %{beacon_key: @other_key}} = Store.load(ctx.store)
    end

    test "cancelling a new mesh leaves the store alone", %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)

      assert submit_upload(view, other_mesh_json()) =~ "Replace the stored mesh?"

      html = view |> element("button[phx-click=cancel_upload]") |> render_click()
      refute html =~ "Replace the stored mesh?"
      assert {:ok, %{seq: 100, beacon_key: "00112233" <> _}} = Store.load(ctx.store)

      # The held dump is gone: a stale confirm does nothing.
      view |> with_target("#tuya-mesh") |> render_click("confirm_upload", %{})
      assert {:ok, %{seq: 100}} = Store.load(ctx.store)
    end

    test "invalid JSON: a friendly error without key material", %{conn: conn} = ctx do
      view = mount_tab(conn)
      truncated = binary_part(KeyLeak.json(), 0, 120)

      html = submit_upload(view, truncated)
      assert html =~ "That file isn&#39;t a usable mesh dump: it isn&#39;t valid JSON"
      refute_secrets(html)
      assert Store.load(ctx.store) == {:error, :no_inventory}
    end

    test "an invalid key names the bulb, never the key", %{conn: conn} do
      view = mount_tab(conn)

      bad =
        KeyLeak.json()
        |> Jason.decode!()
        |> Map.update!("bulbs", fn [b | rest] -> [Map.put(b, "localKey", "short") | rest] end)
        |> Jason.encode!()

      html = submit_upload(view, bad)
      assert html =~ "bulb DC23530FB34A&#39;s localKey isn&#39;t a valid key"
      refute_secrets(html)
    end

    test "too large and wrong type files are refused with upload errors", %{conn: conn} do
      view = mount_tab(conn)

      big = String.duplicate(" ", 65_537)
      {_input, result} = select_file(view, dump_entry(big))
      assert {:error, [[_ref, :too_large]]} = result
      assert render(view) =~ "That file is larger than 64 KB"

      view = mount_tab(conn)

      {_input, result} =
        select_file(view, dump_entry("{}", %{name: "mesh.txt", type: "text/plain"}))

      assert {:error, [[_ref, :not_accepted]]} = result
      assert render(view) =~ "Choose a .json file"
    end

    test "more than one file is refused", %{conn: conn} do
      view = mount_tab(conn)

      input =
        file_input(view, "#tuya-mesh-upload", :inventory, [
          dump_entry("{}", %{name: "a.json"}),
          dump_entry("{}", %{name: "b.json"})
        ])

      assert {:error, _} = render_upload(input, "a.json")
      assert render(view) =~ "Choose one file at a time."
    end

    test "last-seen times advance on the clock tick, without a status change", %{conn: conn} do
      t0 = ~U[2026-11-01 12:00:00Z]
      clock = start_supervised!({Agent, fn -> t0 end})
      Application.put_env(:universal_proxy, :tuya_mesh_clock, fn -> Agent.get(clock, & &1) end)
      on_exit(fn -> Application.delete_env(:universal_proxy, :tuya_mesh_clock) end)

      view = mount_tab(conn)

      status = %{
        TuyaMesh.status()
        | bulbs: [
            %{
              mac: "DC23530FB34A",
              label: "path light 2",
              node_id: 2,
              last_seen: DateTime.add(t0, -120, :second),
              reachable: true
            }
          ]
      }

      assert push_status(view, status) =~ "Seen 2 min ago"

      Agent.update(clock, &DateTime.add(&1, 600, :second))
      send(view.pid, :tuya_mesh_tick)
      _ = render(view)
      assert render(view) =~ "Seen 12 min ago"

      Agent.update(clock, &DateTime.add(&1, 3_600, :second))
      send(view.pid, :tuya_mesh_tick)
      _ = render(view)
      assert render(view) =~ "Seen 1 h ago"
    end

    test "status updates live from the PubSub broadcast", %{conn: conn} do
      view = mount_tab(conn)
      refute render(view) =~ "Running on"

      status = %{
        role_mac: @mesh_mac,
        state: :running,
        reason: nil,
        adapter_index: 1,
        radio: %{ready: true, last_error: nil, queued: 0},
        lights_running: true,
        bulbs: [
          %{
            mac: "DC23530FB34A",
            label: "path light 2",
            node_id: 2,
            last_seen: DateTime.add(DateTime.utc_now(), -120, :second),
            reachable: true
          }
        ],
        groups: [%{local_id: 1, name: "path and post", members: ["DC23530FB34A"]}]
      }

      html = push_status(view, status)

      assert html =~ "Running on hci1."
      assert html =~ "Radio ready."
      assert html =~ "Seen 2 min ago"
      assert html =~ "Reachable"
      assert html =~ "1 bulb"

      not_ready = %{status | radio: %{ready: false, last_error: :not_discovering, queued: 0}}
      html = push_status(view, not_ready)
      assert html =~ "Radio not ready"
      assert html =~ "Radio not ready: not discovering."

      missing = %{
        not_ready
        | state: :idle,
          reason: :adapter_missing,
          radio: nil,
          adapter_index: nil
      }

      assert push_status(view, missing) =~ "Mesh dongle not found."
    end

    test "clear asks first, then clears", %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)

      html = view |> element("button[phx-click=ask_clear]") |> render_click()
      assert html =~ "Clear the Tuya mesh inventory?"

      html = view |> element("button[phx-click=cancel_clear]") |> render_click()
      refute html =~ "Clear the Tuya mesh inventory?"
      assert {:ok, _} = Store.load(ctx.store)

      view |> element("button[phx-click=ask_clear]") |> render_click()
      html = view |> element("button[phx-click=confirm_clear]") |> render_click()

      assert html =~ "Inventory cleared."
      assert Store.load(ctx.store) == {:error, :no_inventory}
      refute html =~ "path light 2"
    end

    @tag :capture_log
    test "an unrecoverable record needs a second, forced clear", %{conn: conn} = ctx do
      :ok = :dets.insert(:sys.get_state(ctx.store).table, {:inventory, %{"bulbs" => []}})
      view = mount_tab(conn)

      # Offline (no Resolver), an unreadable record lists no bulbs and reads
      # as :not_running: Clear is still offered, as the way out.
      assert %{reason: :not_running, bulbs: [], groups: []} = TuyaMesh.status()
      assert has_element?(view, "button[phx-click=ask_clear]")

      view |> element("button[phx-click=ask_clear]") |> render_click()

      # A repeated click on the first dialog's button, queued behind the one
      # that opened the force dialog, does nothing.
      html = view |> with_target("#tuya-mesh") |> render_click("confirm_clear", %{})
      assert html =~ "Clear anyway (sequence will be lost)"
      html = view |> with_target("#tuya-mesh") |> render_click("confirm_clear", %{})
      assert html =~ "Clear anyway (sequence will be lost)"
      assert {:error, {:invalid, _}} = Store.load(ctx.store)

      # With the Resolver up, the same record reports :invalid_inventory.
      html = push_status(view, %{TuyaMesh.status() | reason: :invalid_inventory})
      assert html =~ "The stored inventory can&#39;t be read."
      assert has_element?(view, "button[phx-click=ask_clear]")

      # The force dialog is still the one open.
      html = view |> element("button[phx-click=confirm_force_clear]") |> render_click()
      assert html =~ "Inventory cleared."

      assert Store.load(ctx.store) == {:error, :no_inventory}
    end
  end
end
