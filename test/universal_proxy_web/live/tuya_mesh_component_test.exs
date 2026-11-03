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

  defp token_of(view, event) do
    [token] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("button[phx-click=#{event}]")
      |> LazyHTML.attribute("phx-value-token")

    token
  end

  defp cancel_ids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("button[phx-click=cancel_upload]")
    |> LazyHTML.attribute("id")
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
      # The dump held for the confirm stays sealed in the LiveView process
      # (where the component's state lives), under inspect and ~p alike.
      # Its raw state: the channel's format_status(:normal) only summarises
      # it, but format_status(:terminate) hands the whole state to crash
      # reports.
      KeyLeak.refute_keys(:sys.get_state(view.pid))
      KeyLeak.refute_keys(:sys.get_status(view.pid))
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

    test "a new submit drops the pending confirmation, whatever the new file is",
         %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)
      [b2, _b3] = KeyLeak.json() |> Jason.decode!() |> Map.fetch!("bulbs")
      removal = json(%{"bulbs" => [b2], "groups" => []})

      # While a dialog is open, the form behind it is inert.
      assert submit_upload(view, removal) =~ "Remove 1 bulb?"
      assert has_element?(view, "#tuya-mesh-upload[inert]")
      old = confirm_token(view)

      # An invalid file: an error, and the old dialog is gone.
      html = submit_upload(view, binary_part(KeyLeak.json(), 0, 120))
      assert html =~ "it isn&#39;t valid JSON"
      refute html =~ "Remove 1 bulb?"
      refute has_element?(view, "#tuya-mesh-upload[inert]")

      html =
        view |> with_target("#tuya-mesh") |> render_click("confirm_upload", %{"token" => old})

      refute html =~ "Inventory updated"
      assert {:ok, %{bulbs: [_, _]}} = Store.load(ctx.store)

      # A file that uploads directly (nothing removed): the old dialog's
      # token confirms nothing afterwards.
      assert submit_upload(view, removal) =~ "Remove 1 bulb?"
      old = confirm_token(view)
      html = submit_upload(view, KeyLeak.json())
      assert html =~ "No bulbs or groups were added or removed."
      refute html =~ "Remove 1 bulb?"
      view |> with_target("#tuya-mesh") |> render_click("confirm_upload", %{"token" => old})
      assert {:ok, %{bulbs: [_, _]}} = Store.load(ctx.store)
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

    test "a dump far ahead asks; the default keeps the device's counter", %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)
      ahead = json(%{"seq" => 5_000})

      html = submit_upload(view, ahead)
      assert html =~ "sequence counter (5000) is far ahead of the"
      assert html =~ "device&#39;s (100)"
      assert html =~ "Adopt the dump"
      assert html =~ "keep the device"
      refute_secrets(html)

      # Cancel keeps everything.
      view |> element("button[phx-click=cancel_upload]") |> render_click()
      assert {:ok, %{seq: 100}} = Store.load(ctx.store)

      # The main action uploads, keeping the device's counter.
      submit_upload(view, ahead)
      html = view |> element("button[phx-click=confirm_upload]") |> render_click()
      assert html =~ "Inventory updated (same mesh)."
      assert {:ok, %{seq: 100}} = Store.load(ctx.store)
    end

    test "adopting the dump's counter takes a second, warned confirmation", %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)
      target = with_target(view, "#tuya-mesh")

      submit_upload(view, json(%{"seq" => 5_000}))
      review = token_of(view, "confirm_upload")

      html = render_click(target, "ask_adopt", %{"token" => review})
      assert html =~ "Adopt the dump&#39;s counter?"
      assert html =~ "the bulbs will ignore this"
      assert html =~ "sets the device&#39;s sequence counter to 5000"
      refute has_element?(view, "button[phx-click=confirm_upload]")
      adopt = token_of(view, "confirm_adopt")
      assert adopt != review

      # Focus moves to the new dialog's Cancel.
      assert has_element?(view, "#tuya-mesh-adopt-cancel-#{adopt}")

      # Clicks queued from the review dialog do nothing now.
      render_click(target, "confirm_upload", %{"token" => review})
      render_click(target, "confirm_adopt", %{"token" => review})
      render_click(target, "ask_adopt", %{"token" => review})
      assert token_of(view, "confirm_adopt") == adopt
      assert {:ok, %{seq: 100}} = Store.load(ctx.store)

      html = render_click(target, "confirm_adopt", %{"token" => adopt})
      assert html =~ "Inventory updated (same mesh)."
      assert {:ok, %{seq: 5_000}} = Store.load(ctx.store)

      # Consumed: a repeat does nothing.
      render_click(target, "confirm_adopt", %{"token" => adopt})
      assert {:ok, %{seq: 5_000}} = Store.load(ctx.store)
    end

    test "cancelling the adopt dialog keeps the device's counter", %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)

      submit_upload(view, json(%{"seq" => 5_000}))
      view |> element("button[phx-click=ask_adopt]") |> render_click()
      html = view |> element("button[phx-click=cancel_upload]") |> render_click()
      refute html =~ "Adopt the dump&#39;s counter?"
      assert {:ok, %{seq: 100}} = Store.load(ctx.store)
    end

    test "a dump only slightly ahead, or behind, offers no adoption", %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)

      assert submit_upload(view, json(%{"seq" => 200})) =~ "Inventory updated (same mesh)."
      assert {:ok, %{seq: 200}} = Store.load(ctx.store)

      html = submit_upload(view, json(%{"seq" => 150}))
      refute html =~ "Adopt the dump"
      assert {:ok, %{seq: 200}} = Store.load(ctx.store)
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

    test "the confirmation is an accessible dialog; Escape cancels it", %{conn: conn} = ctx do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view = mount_tab(conn)
      assert submit_upload(view, other_mesh_json()) =~ "Replace the stored mesh?"

      doc = view |> render() |> LazyHTML.from_fragment()
      dialog = LazyHTML.query(doc, "#modal-cancel_upload-content[role=dialog][aria-modal=true]")
      assert Enum.count(dialog) == 1
      [title_id] = LazyHTML.attribute(dialog, "aria-labelledby")

      assert doc |> LazyHTML.query("##{title_id}") |> LazyHTML.text() =~
               "Replace the stored mesh?"

      # Focus moves in on open (Cancel, never the destructive action) and
      # returns to the file picker on close, which exists behind it.
      [cancel] =
        doc
        |> LazyHTML.query("#modal-cancel_upload-content button[phx-click=cancel_upload]")
        |> LazyHTML.attribute("phx-mounted")

      assert cancel =~ ~s("focus")

      [on_remove] =
        doc |> LazyHTML.query("#modal-cancel_upload") |> LazyHTML.attribute("phx-remove")

      assert on_remove =~ "#tuya-mesh-upload input[type=file]"
      assert has_element?(view, "#tuya-mesh-upload input[type=file]")

      # A stale re-ask mounts a new Cancel (new id), so focus moves to it.
      [first_id] = cancel_ids(view)

      {:ok, :new_mesh} =
        TuyaMesh.upload(json(%{"beaconKey" => String.duplicate("ab", 16)}), confirm: true)

      view |> element("button[phx-click=confirm_upload]") |> render_click()
      [second_id] = cancel_ids(view)
      assert second_id != first_id

      html = view |> element("#modal-cancel_upload") |> render_keydown(%{"key" => "Escape"})
      refute html =~ "Replace the stored mesh?"
      assert {:ok, %{seq: 100, beacon_key: "abab" <> _}} = Store.load(ctx.store)
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

    test "a bulb reads Checking until the pinger concludes", %{conn: conn} do
      view = mount_tab(conn)

      bulb = %{
        mac: "DC23530FB34A",
        label: "path light 2",
        node_id: 2,
        last_seen: nil,
        reachable: false,
        checking: true
      }

      status = %{
        TuyaMesh.status()
        | state: :running,
          radio: %{ready: true, last_error: nil, queued: 0},
          bulbs: [bulb]
      }

      html = push_status(view, status)
      assert html =~ "Never seen"
      assert html =~ "Checking…"
      refute html =~ "Not reachable"

      html = push_status(view, %{status | bulbs: [%{bulb | checking: false}]})
      assert html =~ "Not reachable"
      refute html =~ "Checking…"

      html = push_status(view, %{status | bulbs: [%{bulb | reachable: true, checking: false}]})
      assert html =~ "Reachable"
      refute html =~ "Checking…"
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
      # The force dialog's Cancel is a new element that takes focus.
      assert has_element?(view, "#tuya-mesh-force-clear-cancel[phx-mounted]")
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

  describe "colour temperature" do
    setup do
      assign_role()
      :ok
    end

    @settings_form "#tuya-mesh-settings"

    defp settings_view(conn) do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      mount_tab(conn)
    end

    defp change_settings(view, params),
      do: view |> form(@settings_form, settings: params) |> render_change()

    defp save_settings(view, params),
      do: view |> form(@settings_form, settings: params) |> render_submit()

    test "hidden until an inventory is loaded", %{conn: conn} do
      view = mount_tab(conn)
      refute has_element?(view, @settings_form)
    end

    test "shows the stored range in Kelvin, with nothing to save", %{conn: conn} do
      view = settings_view(conn)

      assert has_element?(
               view,
               "#{@settings_form} input[name='settings[warm_k]'][value='2700']"
             )

      assert has_element?(
               view,
               "#{@settings_form} input[name='settings[cool_k]'][value='6500']"
             )

      assert has_element?(view, "#{@settings_form} button[role=switch][aria-checked=false]")
      refute has_element?(view, "#{@settings_form} button[type=submit]")
      assert render(view) =~ "briefly reconnects Home Assistant"
    end

    test "a stored non-default range is shown in Kelvin", %{conn: conn, store: store} do
      :ok = Store.put_settings(%{min_mireds: 200, max_mireds: 333, invert: true}, store)
      view = settings_view(conn)

      assert has_element?(view, "input[name='settings[warm_k]'][value='3000']")
      assert has_element?(view, "input[name='settings[cool_k]'][value='5000']")
      assert has_element?(view, "#{@settings_form} button[role=switch][aria-checked=true]")
    end

    test "a valid save stores the mireds and offers Save only while different",
         %{conn: conn, store: store} do
      view = settings_view(conn)

      change_settings(view, %{warm_k: "3000", cool_k: "5000"})
      assert has_element?(view, "#{@settings_form} button[type=submit]")

      html = save_settings(view, %{warm_k: "3000", cool_k: "5000"})
      assert Store.settings(store) == %{min_mireds: 200, max_mireds: 333, invert: false}
      assert html =~ "Colour temperature saved."
      assert has_element?(view, "input[name='settings[warm_k]'][value='3000']")
      refute has_element?(view, "#{@settings_form} button[type=submit]")

      # Back to the stored values: nothing to save again.
      change_settings(view, %{warm_k: "3000", cool_k: "5100"})
      assert has_element?(view, "#{@settings_form} button[type=submit]")
      change_settings(view, %{warm_k: "3000", cool_k: "5000"})
      refute has_element?(view, "#{@settings_form} button[type=submit]")
    end

    test "the default range saves back to 370 / 154 mireds", %{conn: conn, store: store} do
      :ok = Store.put_settings(%{min_mireds: 200, max_mireds: 333}, store)
      view = settings_view(conn)

      save_settings(view, %{warm_k: "2700", cool_k: "6500"})
      assert Store.settings(store) == %{min_mireds: 154, max_mireds: 370, invert: false}
    end

    test "a range the 50 K display rounds is not an edit after saving", %{
      conn: conn,
      store: store
    } do
      view = settings_view(conn)

      save_settings(view, %{warm_k: "2710", cool_k: "6500"})
      assert Store.settings(store) == %{min_mireds: 154, max_mireds: 369, invert: false}
      assert has_element?(view, "input[name='settings[warm_k]'][value='2700']")
      refute has_element?(view, "#{@settings_form} button[type=submit]")

      # Reloaded, still nothing to save, and an Invert-only save keeps the mireds.
      view = mount_tab(build_conn())
      refute has_element?(view, "#{@settings_form} button[type=submit]")

      view |> element("#{@settings_form} button[role=switch]") |> render_click()
      assert has_element?(view, "#{@settings_form} button[type=submit]")
      save_settings(view, %{warm_k: "2700", cool_k: "6500"})
      assert Store.settings(store) == %{min_mireds: 154, max_mireds: 369, invert: true}

      # Typing the displayed value into the other field still converts it.
      change_settings(view, %{warm_k: "2710", cool_k: "6500"})
      refute has_element?(view, "#{@settings_form} button[type=submit]")
      change_settings(view, %{warm_k: "2700", cool_k: "6000"})
      assert has_element?(view, "#{@settings_form} button[type=submit]")
    end

    test "two stored endpoints that display alike stay valid and exact",
         %{conn: conn, store: store} do
      :ok = Store.put_settings(%{min_mireds: 369, max_mireds: 370}, store)
      view = settings_view(conn)

      assert has_element?(view, "input[name='settings[warm_k]'][value='2700']")
      assert has_element?(view, "input[name='settings[cool_k]'][value='2700']")
      refute render(view) =~ "Must be higher"
      refute has_element?(view, "#{@settings_form} button[type=submit]")

      view |> element("#{@settings_form} button[role=switch]") |> render_click()
      refute render(view) =~ "Must be higher"
      assert has_element?(view, "#{@settings_form} button[type=submit]")

      save_settings(view, %{warm_k: "2700", cool_k: "2700"})
      assert Store.settings(store) == %{min_mireds: 369, max_mireds: 370, invert: true}

      # Editing one field to the same Kelvin as the other is still an error.
      html = change_settings(view, %{warm_k: "3000", cool_k: "3000"})
      assert html =~ "Must be higher than the warm temperature."
    end

    test "a save sends only what this form changed, keeping another tab's newer values",
         %{conn: conn, store: store} do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view_a = mount_tab(conn)
      view_b = mount_tab(build_conn())

      save_settings(view_a, %{warm_k: "3000", cool_k: "5000"})
      assert Store.settings(store) == %{min_mireds: 200, max_mireds: 333, invert: false}

      # B still holds 2700-6500 and only flips Invert.
      view_b |> element("#{@settings_form} button[role=switch]") |> render_click()
      save_settings(view_b, %{warm_k: "2700", cool_k: "6500"})
      assert Store.settings(store) == %{min_mireds: 200, max_mireds: 333, invert: true}

      # B now shows what is stored.
      assert has_element?(view_b, "input[name='settings[warm_k]'][value='3000']")
      assert has_element?(view_b, "input[name='settings[cool_k]'][value='5000']")
    end

    test "a stale edit that no longer fits the stored range is reported inline",
         %{conn: conn, store: store} do
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      view_a = mount_tab(conn)
      view_b = mount_tab(build_conn())

      # A narrows the range to 4000-4500 K (250 / 222 mireds).
      save_settings(view_a, %{warm_k: "4000", cool_k: "4500"})

      # B (baseline 2700-6500) changes only the cool end to 3000 K: 333 mireds
      # is not below the stored warm 250, so the merge is refused.
      html = save_settings(view_b, %{warm_k: "2700", cool_k: "3000"})
      assert html =~ "doesn&#39;t fit the colour temperature stored now"
      assert Store.settings(store) == %{min_mireds: 222, max_mireds: 250, invert: false}

      # B's untouched warm field follows the Store; its edit stays, and is
      # now flagged against A's range, with nothing to save.
      assert has_element?(view_b, "input[name='settings[warm_k]'][value='4000']")
      assert has_element?(view_b, "input[name='settings[cool_k]'][value='3000']")
      assert render(view_b) =~ "Must be higher than the warm temperature."
      refute has_element?(view_b, "#{@settings_form} button[type=submit]")

      # Correcting only the cool field sends just that key: A's warm stays.
      html = change_settings(view_b, %{cool_k: "5000"})
      refute html =~ "Must be higher"
      assert has_element?(view_b, "#{@settings_form} button[type=submit]")
      save_settings(view_b, %{warm_k: "4000", cool_k: "5000"})
      assert Store.settings(store) == %{min_mireds: 200, max_mireds: 250, invert: false}
    end

    test "the invert toggle round-trips", %{conn: conn, store: store} do
      view = settings_view(conn)

      view |> element("#{@settings_form} button[role=switch]") |> render_click()
      assert has_element?(view, "#{@settings_form} button[role=switch][aria-checked=true]")
      assert has_element?(view, "#{@settings_form} input[type=hidden][value=true]")
      assert has_element?(view, "#{@settings_form} button[type=submit]")

      # A text edit keeps the toggled value.
      change_settings(view, %{warm_k: "2700"})
      assert has_element?(view, "#{@settings_form} button[role=switch][aria-checked=true]")

      save_settings(view, %{warm_k: "2700", cool_k: "6500"})
      assert %{invert: true, min_mireds: 154, max_mireds: 370} = Store.settings(store)
      refute has_element?(view, "#{@settings_form} button[type=submit]")

      # A fresh mount shows it on, and toggling off saves it back.
      view = mount_tab(build_conn())
      assert has_element?(view, "#{@settings_form} button[role=switch][aria-checked=true]")

      view |> element("#{@settings_form} button[role=switch]") |> render_click()
      save_settings(view, %{warm_k: "2700", cool_k: "6500"})
      assert %{invert: false} = Store.settings(store)
    end

    test "invalid input shows errors and saves nothing", %{conn: conn, store: store} do
      view = settings_view(conn)
      stored = Store.settings(store)

      for {params, message} <- [
            {%{warm_k: "warm", cool_k: "6500"}, "Enter a whole number of Kelvin."},
            {%{warm_k: "", cool_k: "6500"}, "Enter a whole number of Kelvin."},
            {%{warm_k: "2700.5", cool_k: "6500"}, "Enter a whole number of Kelvin."},
            {%{warm_k: "500", cool_k: "6500"}, "Must be between 1000 and 10000 K."},
            {%{warm_k: "2700", cool_k: "20000"}, "Must be between 1000 and 10000 K."},
            {%{warm_k: "5000", cool_k: "5000"}, "Must be higher than the warm temperature."},
            {%{warm_k: "6500", cool_k: "2700"}, "Must be higher than the warm temperature."},
            {%{warm_k: "9999", cool_k: "10000"}, "Too close to the warm temperature."}
          ] do
        html = change_settings(view, params)
        assert html =~ message, "#{inspect(params)} should say #{message}"
        refute has_element?(view, "#{@settings_form} button[type=submit]")

        save_settings(view, params)
        assert Store.settings(store) == stored
      end

      change_settings(view, %{warm_k: "2700", cool_k: "6500"})
      refute render(view) =~ "Enter a whole number"
    end

    test "a save while the Store is down keeps form and baseline; the retry sends only the edit",
         %{conn: conn, tmp_dir: tmp_dir, store: store} do
      :ok = Store.put_settings(%{min_mireds: 200, max_mireds: 333}, store)
      view = settings_view(conn)
      change_settings(view, %{warm_k: "3500", cool_k: "5000"})
      stop_supervised!(Store)

      html = save_settings(view, %{warm_k: "3500", cool_k: "5000"})
      assert html =~ "The Tuya mesh service isn&#39;t available right now."

      # Not rebased onto the defaults the facade answers with meanwhile.
      assert has_element?(view, "input[name='settings[warm_k]'][value='3500']")
      assert has_element?(view, "input[name='settings[cool_k]'][value='5000']")
      assert has_element?(view, "#{@settings_form} button[type=submit]")

      store =
        start_supervised!(
          {Store,
           enabled: true,
           table: :"tuya_ui_store_restart_#{System.unique_integer([:positive])}",
           dets_path: Path.join(tmp_dir, "mesh.dets")}
        )

      # Another tab moved the cool end meanwhile; the retry only sends warm.
      :ok = Store.put_settings(%{min_mireds: 180}, store)
      save_settings(view, %{warm_k: "3500", cool_k: "5000"})
      assert Store.settings(store) == %{min_mireds: 180, max_mireds: 286, invert: false}
    end
  end
end
