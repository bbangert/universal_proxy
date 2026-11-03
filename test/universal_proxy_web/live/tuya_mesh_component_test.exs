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

  defmodule FakeLights do
    @moduledoc """
    Stands in for `TuyaBeaconMesh.Lights` under its registered name (the
    facade's default): answers the group calls from a `group_sync`-shaped
    view, reports each request to the test as `{:lights_call, request}`,
    and replies with `reply/2`'s override for a kind of request while one
    is set. Without one, changes apply to the view with every touched
    member `:pending`.
    """
    use GenServer

    @name UniversalProxy.TuyaBeaconMesh.Lights

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: @name)

    def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

    @doc "Sets (or, with `nil`, clears) the reply for one kind of request."
    def reply(kind, reply), do: GenServer.call(@name, {:fake_reply, kind, reply})

    def update(fun), do: GenServer.call(@name, {:fake_update, fun})

    @impl GenServer
    def init(opts), do: {:ok, %{test: opts[:test], view: opts[:view], replies: %{}}}

    @impl GenServer
    def handle_call({:fake_reply, kind, reply}, _from, state),
      do: {:reply, :ok, put_in(state.replies[kind], reply)}

    def handle_call({:fake_update, fun}, _from, state),
      do: {:reply, :ok, %{state | view: fun.(state.view)}}

    def handle_call(:groups, _from, state) do
      send(state.test, {:lights_call, :groups})
      {:reply, state.replies[:groups] || {:ok, state.view}, state}
    end

    def handle_call(request, _from, state) do
      send(state.test, {:lights_call, request})

      case state.replies[elem(request, 0)] do
        nil ->
          {reply, view} = apply_change(request, state.view)
          {:reply, reply, %{state | view: view}}

        reply ->
          {:reply, reply, state}
      end
    end

    defp apply_change({:create_group, name, members}, view) do
      gid = view.groups |> Enum.map(& &1.local_id) |> Enum.max(fn -> 0 end) |> Kernel.+(1)

      group = %{
        local_id: gid,
        name: String.trim(name),
        members: members,
        holders: members,
        deleted: false,
        sync: Map.new(members, &{&1, %{op: :add, state: :pending}})
      }

      {{:ok, gid}, %{view | groups: view.groups ++ [group]}}
    end

    defp apply_change({:add_member, gid, mac}, view),
      do: {:ok, edit(view, gid, &member(&1, mac, :add))}

    defp apply_change({:remove_member, gid, mac}, view),
      do: {:ok, edit(view, gid, &member(&1, mac, :remove))}

    defp apply_change({:rename_group, gid, name}, view),
      do: {:ok, edit(view, gid, &%{&1 | name: String.trim(name)})}

    defp apply_change({:delete_group, gid, _opts}, view) do
      leave = fn g ->
        sync = Map.new(g.holders, &{&1, %{op: :remove, state: :pending}})
        %{g | name: nil, members: [], deleted: true, sync: sync}
      end

      {:ok, edit(view, gid, leave)}
    end

    defp apply_change(_request, view), do: {{:error, :unknown_request}, view}

    defp edit(view, gid, fun),
      do: %{view | groups: Enum.map(view.groups, &if(&1.local_id == gid, do: fun.(&1), else: &1))}

    defp member(g, mac, op) do
      members = if op == :add, do: Enum.uniq(g.members ++ [mac]), else: g.members -- [mac]

      %{
        g
        | members: members,
          holders: Enum.uniq(g.holders ++ [mac]),
          sync: Map.put(g.sync, mac, %{op: op, state: :pending})
      }
    end
  end

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

  describe "groups" do
    @mac2 "DC23530FB34A"
    @mac3 "DC23533FCD62"

    setup do
      assign_role()
      {:ok, _} = TuyaMesh.upload(KeyLeak.json())
      Application.put_env(:universal_proxy, :tuya_group_poll_ms, 30)
      on_exit(fn -> Application.delete_env(:universal_proxy, :tuya_group_poll_ms) end)
      :ok
    end

    defp start_lights(view \\ initial_view()) do
      start_supervised!({FakeLights, test: self(), view: view})
    end

    defp initial_view do
      %{
        groups: [group(1, "path and post", [@mac2, @mac3])],
        slots: %{@mac2 => 1, @mac3 => 1}
      }
    end

    defp group(gid, name, members, sync \\ %{}) do
      %{
        local_id: gid,
        name: name,
        members: members,
        holders: members,
        deleted: false,
        sync: sync
      }
    end

    # Every call but the reads.
    defp changes do
      receive do
        {:lights_call, :groups} -> changes()
        {:lights_call, request} -> [request | changes()]
      after
        0 -> []
      end
    end

    defp click(view, selector), do: view |> element(selector) |> render_click()

    defp open_new_group(view), do: click(view, "button[phx-click=new_group]")

    defp group_form(view, params), do: form(view, "#tuya-group-form", group: params)

    test "without Lights the groups are listed read-only", %{conn: conn} do
      view = mount_tab(conn)
      html = render(view)
      assert html =~ "path and post"
      assert html =~ "Groups can be edited while the mesh is running."
      refute has_element?(view, "button[phx-click=new_group]")
      refute has_element?(view, "button[phx-click=edit_members]")
      refute html =~ "briefly reconnects Home Assistant."
    end

    test "Lights stopping turns the editor read-only", %{conn: conn} do
      start_lights()
      view = mount_tab(conn)
      assert has_element?(view, "button[phx-click=new_group]")

      assert render(view) =~
               "Creating, renaming or deleting a group briefly reconnects Home Assistant."

      stop_supervised!(FakeLights)
      html = push_status(view, TuyaMesh.status())
      assert html =~ "Groups can be edited while the mesh is running."
      assert html =~ "path and post"
      refute has_element?(view, "button[phx-click=new_group]")
    end

    test "create sends one call with the name and the ticked bulbs", %{conn: conn} do
      start_lights()
      view = mount_tab(conn)

      html = open_new_group(view)
      assert html =~ "New group"
      assert has_element?(view, "#tuya-group-form input[name='group[name]']")
      refute has_element?(view, "button[phx-click=new_group]")

      view |> group_form(%{name: "porch", members: [@mac2]}) |> render_change()
      _ = changes()
      html = view |> group_form(%{name: "  porch "}) |> render_submit()

      assert changes() == [{:create_group, "  porch ", [@mac2]}]
      assert html =~ "Group “porch” created."
      assert html =~ "Home Assistant reconnects briefly"
      refute has_element?(view, "#tuya-group-form")
      assert has_element?(view, "#tuya-group-2", "porch")
      assert has_element?(view, "#tuya-group-2", "Joining…")
      refute_secrets(render(view))
    end

    test "create errors are shown in the form, which stays open", %{conn: conn} do
      start_lights()
      view = mount_tab(conn)
      open_new_group(view)

      cases = [
        {{:error, :duplicate_group_name}, "Another group already has that name."},
        {{:error, :bad_group_name}, "Enter a name of 1 to 64 characters."},
        {{:error, {:group_slots_full, @mac3}},
         "post spot 1 already belongs to 8 groups, the most a bulb can hold."},
        {{:error, :no_free_group_id}, "Every group id is in use."},
        {{:error, :persist_failed}, "couldn&#39;t be saved on this device"},
        {{:error, :not_running}, "The mesh isn&#39;t running"},
        {{:error, :timeout}, "may still have been applied"}
      ]

      for {reply, text} <- cases do
        FakeLights.reply(:create_group, reply)
        html = view |> group_form(%{name: "path and post", members: [@mac3]}) |> render_submit()
        assert html =~ text, inspect(reply)
        assert has_element?(view, "#tuya-group-form")
      end

      assert length(changes()) == length(cases)
    end

    test "a failure that leaves the editor read-only is shown in the section", %{conn: conn} do
      start_lights()
      view = mount_tab(conn)
      open_new_group(view)
      FakeLights.reply(:create_group, {:error, :not_running})
      FakeLights.reply(:groups, {:error, :not_running})

      html = view |> group_form(%{name: "porch", members: [@mac2]}) |> render_submit()
      assert html =~ "The mesh isn&#39;t running, so groups can&#39;t be changed right now."
      assert html =~ "Groups can be edited while the mesh is running."
      refute has_element?(view, "#tuya-group-form")
    end

    test "a bulb with all 8 slots used can't be ticked unless it holds the group",
         %{conn: conn} do
      start_lights(%{
        groups: [group(1, "path and post", [@mac3]), group(2, "spare", [])],
        slots: %{@mac2 => 3, @mac3 => 8}
      })

      view = mount_tab(conn)
      open_new_group(view)
      assert has_element?(view, "#tuya-group-form input[value=#{@mac3}][disabled]")
      refute has_element?(view, "#tuya-group-form input[value=#{@mac2}][disabled]")
      assert render(view) =~ "8/8"
      assert render(view) =~ "3/8"

      # Group 1 holds it already: it stays editable there.
      click(view, "#tuya-group-1 button[phx-click=edit_members]")
      refute has_element?(view, "#tuya-group-form input[value=#{@mac3}][disabled]")

      click(view, "#tuya-group-2 button[phx-click=edit_members]")
      assert has_element?(view, "#tuya-group-form input[value=#{@mac3}][disabled]")
    end

    test "rename sends one call; an unchanged name sends none", %{conn: conn} do
      start_lights()
      view = mount_tab(conn)

      click(view, "#tuya-group-1 button[phx-click=rename_group]")
      assert has_element?(view, "#tuya-group-1 #tuya-group-form input[value='path and post']")
      view |> group_form(%{name: "path and post"}) |> render_submit()
      refute has_element?(view, "#tuya-group-form")

      click(view, "#tuya-group-1 button[phx-click=rename_group]")
      FakeLights.reply(:rename_group, {:error, :duplicate_group_name})
      html = view |> group_form(%{name: "taken"}) |> render_submit()
      assert html =~ "Another group already has that name."

      FakeLights.reply(:rename_group, nil)
      html = view |> group_form(%{name: "garden"}) |> render_submit()
      assert changes() == [{:rename_group, 1, "taken"}, {:rename_group, 1, "garden"}]
      assert html =~ "Group renamed to “garden”."
      assert has_element?(view, "#tuya-group-1", "garden")
    end

    test "a rename form keeps the name it showed: another tab's rename isn't undone",
         %{conn: conn} do
      start_lights()
      view = mount_tab(conn)
      click(view, "#tuya-group-1 button[phx-click=rename_group]")

      FakeLights.update(fn v ->
        %{v | groups: Enum.map(v.groups, &%{&1 | name: "garden"})}
      end)

      # Saved as shown: no rename back.
      view |> group_form(%{name: "path and post"}) |> render_submit()
      refute has_element?(view, "#tuya-group-form")

      # Typed the name the group already has: nothing to send either.
      click(view, "#tuya-group-1 button[phx-click=rename_group]")
      view |> group_form(%{name: " garden "}) |> render_submit()
      assert changes() == []

      click(view, "#tuya-group-1 button[phx-click=rename_group]")
      view |> group_form(%{name: "porch"}) |> render_submit()
      assert changes() == [{:rename_group, 1, "porch"}]
    end

    test "an imported name with whitespace saved unchanged sends no rename", %{conn: conn} do
      start_lights(%{groups: [group(1, " porch ", [@mac2])], slots: %{}})
      view = mount_tab(conn)

      for input <- [" porch ", "porch"] do
        click(view, "#tuya-group-1 button[phx-click=rename_group]")
        view |> group_form(%{name: input}) |> render_submit()
        refute has_element?(view, "#tuya-group-form")
      end

      assert changes() == []
    end

    test "a ticked bulb that fills up stays enabled and is submitted", %{conn: conn} do
      start_lights(%{groups: [group(1, "path and post", [@mac2])], slots: %{@mac3 => 7}})
      view = mount_tab(conn)
      open_new_group(view)
      view |> group_form(%{name: "porch", members: [@mac3]}) |> render_change()

      FakeLights.update(&%{&1 | slots: %{@mac3 => 8}})
      push_status(view, TuyaMesh.status())
      assert render(view) =~ "8/8"
      assert has_element?(view, "#tuya-group-form input[value=#{@mac3}][checked]")
      refute has_element?(view, "#tuya-group-form input[value=#{@mac3}][disabled]")

      FakeLights.reply(:create_group, {:error, {:group_slots_full, @mac3}})
      html = view |> form("#tuya-group-form") |> render_submit()
      assert changes() == [{:create_group, "porch", [@mac3]}]
      assert html =~ "post spot 1 already belongs to 8 groups"
    end

    test "the delete dialog returns focus to the groups heading", %{conn: conn} do
      start_lights()
      view = mount_tab(conn)
      assert has_element?(view, ~s(#tuya-mesh-groups-title[tabindex="-1"]))

      click(view, "#tuya-group-1 button[phx-click=ask_delete_group]")

      [on_remove] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#modal-cancel_delete_group")
        |> LazyHTML.attribute("phx-remove")

      assert on_remove =~ "#tuya-mesh-groups-title"

      click(view, "button[phx-click=confirm_delete_group]")
      assert has_element?(view, "#tuya-mesh-groups-title")
    end

    test "delete asks first and never sends the dismiss", %{conn: conn} do
      start_lights()
      view = mount_tab(conn)

      html = click(view, "#tuya-group-1 button[phx-click=ask_delete_group]")
      assert html =~ "Delete the group “path and post”?"
      assert html =~ "Its 2 bulbs are asked to leave it"
      html = click(view, "button[phx-click=cancel_delete_group]")
      refute html =~ "Delete the group"
      assert changes() == []

      click(view, "#tuya-group-1 button[phx-click=ask_delete_group]")
      html = click(view, "button[phx-click=confirm_delete_group]")
      assert changes() == [{:delete_group, 1, []}]
      assert html =~ "Group “path and post” deleted."
      refute html =~ "Delete the group"

      # The fake keeps it as an absent group its bulbs may still hold.
      assert has_element?(view, "#tuya-group-1", "Leaving")
      refute has_element?(view, "#tuya-group-1 button[phx-click=edit_members]")
    end

    test "a repeated delete confirm does nothing", %{conn: conn} do
      start_lights()
      view = mount_tab(conn)
      click(view, "#tuya-group-1 button[phx-click=ask_delete_group]")
      click(view, "button[phx-click=confirm_delete_group]")
      view |> with_target("#tuya-mesh") |> render_click("confirm_delete_group", %{})
      assert changes() == [{:delete_group, 1, []}]
    end

    test "member edits send only the changes, as add and remove calls", %{conn: conn} do
      start_lights(%{
        groups: [group(1, "path and post", [@mac2])],
        slots: %{@mac2 => 1, @mac3 => 0}
      })

      view = mount_tab(conn)
      click(view, "#tuya-group-1 button[phx-click=edit_members]")
      assert has_element?(view, "#tuya-group-form input[value=#{@mac2}][checked]")

      html = view |> group_form(%{members: [@mac3]}) |> render_submit()
      assert changes() == [{:add_member, 1, @mac3}, {:remove_member, 1, @mac2}]
      assert html =~ "Member changes sent."
      refute has_element?(view, "#tuya-group-form")
      assert has_element?(view, "#tuya-group-1", "Joining…")
      assert has_element?(view, "#tuya-group-1", "Leaving…")

      # Saved unchanged: nothing is sent.
      click(view, "#tuya-group-1 button[phx-click=edit_members]")
      view |> group_form(%{members: [@mac3]}) |> render_submit()
      assert changes() == []
    end

    test "a refused member change keeps the form, retrying only what failed", %{conn: conn} do
      start_lights(%{
        groups: [group(1, "path and post", [@mac2])],
        slots: %{@mac2 => 1, @mac3 => 7}
      })

      view = mount_tab(conn)
      click(view, "#tuya-group-1 button[phx-click=edit_members]")
      FakeLights.reply(:add_member, {:error, {:group_slots_full, @mac3}})
      html = view |> group_form(%{members: [@mac3]}) |> render_submit()

      assert html =~ "post spot 1 already belongs to 8 groups"
      # The removal went through: no blanket "nothing changed".
      refute html =~ "Nothing was"
      assert changes() == [{:add_member, 1, @mac3}, {:remove_member, 1, @mac2}]
      assert has_element?(view, "#tuya-group-form")

      FakeLights.reply(:add_member, nil)
      view |> group_form(%{members: [@mac3]}) |> render_submit()
      assert changes() == [{:add_member, 1, @mac3}]
      refute has_element?(view, "#tuya-group-form")
    end

    test "a partial failure's retry leaves another tab's member alone", %{conn: conn} do
      [b2, b3] = KeyLeak.json() |> Jason.decode!() |> Map.fetch!("bulbs")

      porch = %{
        "mac" => "DC2353000001",
        "localKey" => @new_local_key,
        "nodeId" => 9,
        "label" => "porch"
      }

      {:ok, :same_mesh} = TuyaMesh.upload(json(%{"bulbs" => [b2, b3, porch]}))
      start_lights(%{groups: [group(1, "path and post", [@mac2])], slots: %{}})
      view = mount_tab(conn)
      click(view, "#tuya-group-1 button[phx-click=edit_members]")

      # Another tab adds porch while this form is open.
      FakeLights.update(fn v ->
        %{v | groups: Enum.map(v.groups, &%{&1 | members: &1.members ++ ["DC2353000001"]})}
      end)

      FakeLights.reply(:add_member, {:error, {:group_slots_full, @mac3}})
      view |> group_form(%{members: [@mac3]}) |> render_submit()
      assert changes() == [{:add_member, 1, @mac3}, {:remove_member, 1, @mac2}]

      FakeLights.reply(:add_member, nil)
      view |> group_form(%{members: [@mac3]}) |> render_submit()
      assert changes() == [{:add_member, 1, @mac3}]
    end

    test "an editor or confirmation whose group another tab deleted sends nothing",
         %{conn: conn} do
      start_lights()
      view = mount_tab(conn)

      absent = fn v ->
        groups = Enum.map(v.groups, &%{&1 | name: nil, members: [], deleted: true})
        %{v | groups: groups}
      end

      click(view, "#tuya-group-1 button[phx-click=edit_members]")
      click(view, "#tuya-group-1 button[phx-click=ask_delete_group]")
      FakeLights.update(absent)

      html = click(view, "button[phx-click=confirm_delete_group]")
      assert html =~ "That group was deleted or replaced in the meantime."
      refute html =~ "Delete the group"

      view |> with_target("#tuya-mesh") |> render_submit("save_group_form", %{})
      assert changes() == []
    end

    test "a confirmation or form whose group was replaced under the same id sends nothing",
         %{conn: conn} = ctx do
      start_lights()
      view = mount_tab(conn)
      inv = UniversalProxy.TuyaBeaconMesh.Inventory.decode!(KeyLeak.json())

      # Another tab deletes group 1 and creates a new group that takes id 1
      # (a new sub-device id), without this tab hearing of it.
      replace_group_1 = fn ->
        {:ok, _} = Store.replace(%{inv | groups: []}, [], ctx.store)
        {:ok, _} = Store.replace(inv, [], ctx.store)
      end

      click(view, "#tuya-group-1 button[phx-click=ask_delete_group]")
      replace_group_1.()
      html = click(view, "button[phx-click=confirm_delete_group]")
      assert html =~ "That group was deleted or replaced in the meantime."

      click(view, "#tuya-group-1 button[phx-click=rename_group]")
      replace_group_1.()
      html = view |> group_form(%{name: "garden"}) |> render_submit()
      assert html =~ "That group was deleted or replaced in the meantime."
      assert changes() == []

      # A status update closes a replaced group's dialog straight away.
      click(view, "#tuya-group-1 button[phx-click=ask_delete_group]")
      replace_group_1.()
      refute push_status(view, TuyaMesh.status()) =~ "Delete the group"
      assert changes() == []
    end

    test "a failed first group keeps the section and its error on screen", %{conn: conn} do
      {:ok, :same_mesh} = TuyaMesh.upload(json(%{"groups" => []}))
      start_lights(%{groups: [], slots: %{}})
      view = mount_tab(conn)
      open_new_group(view)
      FakeLights.reply(:create_group, {:error, :not_running})
      FakeLights.reply(:groups, {:error, :not_running})

      html = view |> group_form(%{name: "porch", members: [@mac2]}) |> render_submit()
      assert html =~ "The mesh isn&#39;t running, so groups can&#39;t be changed right now."
      assert has_element?(view, "#tuya-mesh-groups")
    end

    test "sync states per member; Retry re-sends an unconfirmed change", %{conn: conn} do
      sync = %{
        @mac2 => %{op: :add, state: :confirmed},
        @mac3 => %{op: :add, state: :unconfirmed}
      }

      start_lights(%{groups: [group(1, "path and post", [@mac2, @mac3], sync)], slots: %{}})
      view = mount_tab(conn)

      assert has_element?(view, "#tuya-group-1", "Confirmed")
      assert has_element?(view, "#tuya-group-1", "Join unconfirmed")

      assert has_element?(
               view,
               "#tuya-group-1 button[phx-click=retry_member][phx-value-mac=#{@mac3}]"
             )

      refute has_element?(
               view,
               "#tuya-group-1 button[phx-click=retry_member][phx-value-mac=#{@mac2}]"
             )

      html = click(view, "#tuya-group-1 button[phx-click=retry_member]")
      assert changes() == [{:add_member, 1, @mac3}]
      assert html =~ "Sent again to post spot 1."
      assert has_element?(view, "#tuya-group-1", "Joining…")
    end

    test "an unconfirmed removal retries as a removal; a stale retry sends nothing",
         %{conn: conn} do
      sync = %{@mac3 => %{op: :remove, state: :unconfirmed}}
      start_lights(%{groups: [group(1, "path and post", [@mac2], sync)], slots: %{}})
      view = mount_tab(conn)

      assert has_element?(view, "#tuya-group-1", "Leave unconfirmed")
      click(view, "#tuya-group-1 button[phx-click=retry_member]")
      assert changes() == [{:remove_member, 1, @mac3}]

      # Already pending again: a queued second click is dropped.
      view
      |> with_target("#tuya-mesh")
      |> render_click("retry_member", %{"gid" => "1", "mac" => @mac3})

      assert changes() == []
    end

    test "absent groups show as Leaving with their holders until pruned", %{conn: conn} do
      leaving = %{
        group(7, nil, [], %{@mac2 => %{op: :remove, state: :unconfirmed}})
        | deleted: true,
          holders: [@mac2]
      }

      start_lights(%{groups: [group(1, "path and post", [@mac3]), leaving], slots: %{}})
      view = mount_tab(conn)

      assert has_element?(view, "#tuya-group-7", "Group 7")
      assert has_element?(view, "#tuya-group-7", "Leaving")
      assert has_element?(view, "#tuya-group-7", "Still held by path light 2")
      refute has_element?(view, "#tuya-group-7 button[phx-click=edit_members]")
      refute has_element?(view, "#tuya-group-7 button[phx-click=retry_member]")

      html = click(view, "#tuya-group-7 button[phx-click=retry_removal]")
      assert changes() == [{:delete_group, 7, []}]
      assert html =~ "Removal sent again."

      FakeLights.update(fn v -> %{v | groups: Enum.reject(v.groups, & &1.deleted)} end)
      refute push_status(view, TuyaMesh.status()) =~ "Group 7"
    end

    test "polls only while a change is pending", %{conn: conn} do
      start_lights()
      view = mount_tab(conn)
      _ = render(view)
      flush_reads()
      Process.sleep(150)
      refute_received {:lights_call, :groups}

      open_new_group(view)
      view |> group_form(%{name: "porch", members: [@mac2]}) |> render_submit()

      # Pending: polled again on its own, without a status change.
      flush_reads()
      assert_receive {:lights_call, :groups}, 500
      assert_receive {:lights_call, :groups}, 500

      FakeLights.update(fn v ->
        groups =
          Enum.map(v.groups, fn g ->
            %{g | sync: Map.new(g.sync, fn {m, s} -> {m, %{s | state: :confirmed}} end)}
          end)

        %{v | groups: groups}
      end)

      assert_receive {:lights_call, :groups}, 500
      _ = render(view)
      flush_reads()
      Process.sleep(150)
      refute_received {:lights_call, :groups}
      assert has_element?(view, "#tuya-group-2", "Confirmed")
    end

    test "a change already pending at mount is polled", %{conn: conn} do
      sync = %{@mac2 => %{op: :add, state: :pending}}
      start_lights(%{groups: [group(1, "path and post", [@mac2], sync)], slots: %{}})
      view = mount_tab(conn)
      _ = render(view)
      flush_reads()
      assert_receive {:lights_call, :groups}, 500
      assert_receive {:lights_call, :groups}, 500
    end

    test "a crafted form event can't add fields the open form lacks", %{conn: conn} do
      start_lights()
      view = mount_tab(conn)
      click(view, "#tuya-group-1 button[phx-click=edit_members]")

      view
      |> with_target("#tuya-mesh")
      |> render_change("group_form_change", %{"group" => %{"name" => "x", "members" => ["nope"]}})

      view |> with_target("#tuya-mesh") |> render_submit("save_group_form", %{})
      assert changes() == [{:remove_member, 1, @mac2}, {:remove_member, 1, @mac3}]
    end

    defp flush_reads do
      receive do
        {:lights_call, :groups} -> flush_reads()
      after
        0 -> :ok
      end
    end
  end
end
