defmodule UniversalProxyWeb.MilkDropComponentTest do
  @moduledoc """
  The MilkDrop visualizer section on the Audio tab, against a real
  `UniversalProxy.MilkDrop.Store` (tmp DETS) and `UniversalProxy.MilkDrop.Pack`
  (tmp root, `Req.Test` stub) under their global names, which the host
  leaves free (`MilkDrop.Supervisor` is `:ignore` here). The flag is forced
  on with AudioLive's `:milkdrop_ui_override` app env.
  """

  # async: false — global process names, a shared Req.Test stub, the app
  # env override and global PubSub topics.
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias UniversalProxy.MilkDrop
  alias UniversalProxy.MilkDrop.{Pack, Store}

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub
  @stub __MODULE__
  @version "2026.11.1"
  @url "https://example.test/up-milkdrop-pack-2026.11.1.tar.gz"

  @moduletag :tmp_dir

  setup {Req.Test, :set_req_test_to_shared}

  setup %{tmp_dir: tmp_dir} do
    Application.put_env(:universal_proxy, :milkdrop_ui_override, true)
    on_exit(fn -> Application.delete_env(:universal_proxy, :milkdrop_ui_override) end)

    start_supervised!(
      {Store, table: :milkdrop_component_test, dets_path: Path.join(tmp_dir, "settings.dets")}
    )

    {:ok,
     conn: build_conn(), root: Path.join(tmp_dir, "milkdrop"), src: Path.join(tmp_dir, "src")}
  end

  defp start_pack(root, pin) do
    tasks = start_supervised!(Task.Supervisor)

    start_supervised!(
      {Pack, root: root, pin: pin, task_supervisor: tasks, req_options: [plug: {Req.Test, @stub}]}
    )
  end

  defp good_pack(src) do
    File.mkdir_p!(src)
    path = Path.join(src, "pack.tar.gz")

    :ok =
      :erl_tar.create(
        to_charlist(path),
        [{~c"manifest.json", ~s({"presets":[]})}, {~c"presets/a.milk", "x"}],
        [:compressed]
      )

    File.read!(path)
  end

  defp pin(body),
    do: %{version: @version, url: @url, sha256: :crypto.hash(:sha256, body) |> Base.encode16()}

  defp extracted!(root) do
    dir = Path.join(root, @version)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "manifest.json"), "{}")
  end

  defp ready_pack(%{root: root}) do
    extracted!(root)
    start_pack(root, %{version: @version, url: @url, sha256: String.duplicate("a", 64)})
    :ok
  end

  defp wait_until(fun, timeout \\ 2_000) do
    cond do
      fun.() ->
        :ok

      timeout <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        wait_until(fun, timeout - 10)
    end
  end

  defp toggle_checked?(view, selector) do
    view |> element(selector) |> render() =~ ~s(aria-checked="true")
  end

  describe "visibility" do
    test "hidden while MilkDrop is disabled", %{conn: conn, root: root} do
      start_pack(root, nil)
      Application.put_env(:universal_proxy, :milkdrop_ui_override, false)

      {:ok, view, html} = live(conn, "/audio")
      refute html =~ "MilkDrop visualizer"
      refute has_element?(view, "#milkdrop")
    end

    test "hidden on the host without the override (an unsupported target)", %{conn: conn} do
      Application.delete_env(:universal_proxy, :milkdrop_ui_override)
      refute MilkDrop.enabled?()

      {:ok, _view, html} = live(conn, "/audio")
      refute html =~ "MilkDrop visualizer"
    end

    test "shown while enabled, with the defaults", %{conn: conn, root: root} do
      start_pack(root, nil)

      {:ok, view, html} = live(conn, "/audio")
      assert html =~ "MilkDrop visualizer"
      assert has_element?(view, "#milkdrop-rotate[value=\"20\"]")
      assert render(view) =~ "20 s"
      refute toggle_checked?(view, "#milkdrop-high-frequency")
    end
  end

  describe "pack status" do
    test "absent offers Download", %{conn: conn, root: root, src: src} do
      start_pack(root, pin(good_pack(src)))

      {:ok, view, _html} = live(conn, "/audio")
      assert render(view) =~ "Not downloaded"
      assert view |> element("#milkdrop-ensure") |> render() =~ "Download"
    end

    test "ready shows its version and no button", %{conn: conn} = ctx do
      ready_pack(ctx)

      {:ok, view, _html} = live(conn, "/audio")
      html = render(view)
      assert html =~ "Ready"
      assert html =~ "Version #{@version}"
      refute has_element?(view, "#milkdrop-ensure")
    end

    test "downloading and failed statuses arrive over PubSub", %{conn: conn, root: root} do
      start_pack(root, nil)
      {:ok, view, _html} = live(conn, "/audio")

      Phoenix.PubSub.broadcast(
        @pubsub,
        MilkDrop.pack_topic(),
        {:milkdrop_pack, {:downloading, 42}}
      )

      wait_until(fn -> has_element?(view, "#milkdrop-pack-progress[aria-valuenow=\"42\"]") end)
      assert render(view) =~ "Downloading"
      refute has_element?(view, "#milkdrop-ensure")

      Phoenix.PubSub.broadcast(
        @pubsub,
        MilkDrop.pack_topic(),
        {:milkdrop_pack, {:error, :checksum_mismatch}}
      )

      wait_until(fn -> render(view) =~ "The download didn&#39;t match its checksum." end)
      refute has_element?(view, "#milkdrop-pack-progress")
      assert view |> element("#milkdrop-ensure") |> render() =~ "Retry"

      # A restarted Pack announces its starting status the same way.
      Phoenix.PubSub.broadcast(
        @pubsub,
        MilkDrop.pack_topic(),
        {:milkdrop_pack_started, {:ready, "2026.12.0", "/x"}}
      )

      wait_until(fn -> render(view) =~ "Version 2026.12.0" end)
    end

    test "Download runs Pack.ensure and follows it to ready", %{conn: conn, root: root, src: src} do
      body = good_pack(src)
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        send(test_pid, :pack_requested)
        Plug.Conn.send_resp(conn, 200, body)
      end)

      start_pack(root, pin(body))
      {:ok, view, _html} = live(conn, "/audio")

      view |> element("#milkdrop-ensure") |> render_click()
      render_async(view)

      assert_receive :pack_requested, 2_000
      wait_until(fn -> render(view) =~ "Version #{@version}" end)
      assert {:ready, @version, _dir} = Pack.status()
    end

    test "an ensure failure shows the reason and offers Retry", %{conn: conn, root: root} do
      start_pack(root, nil)
      {:ok, view, _html} = live(conn, "/audio")

      view |> element("#milkdrop-ensure") |> render_click()
      render_async(view)

      wait_until(fn -> render(view) =~ "This firmware doesn&#39;t pin a preset pack." end)
      assert view |> element("#milkdrop-ensure") |> render() =~ "Retry"
    end

    test "an ensure answer from before a Pack restart doesn't overwrite its status",
         %{conn: conn} do
      test_pid = self()

      fake =
        spawn_link(fn ->
          fake_pack = fn fake_pack ->
            receive do
              {:"$gen_call", from, :ensure} ->
                send(test_pid, {:ensure_called, from})
                fake_pack.(fake_pack)

              {:"$gen_call", from, :status} ->
                GenServer.reply(from, :absent)
                fake_pack.(fake_pack)
            end
          end

          fake_pack.(fake_pack)
        end)

      Process.register(fake, Pack)

      {:ok, view, _html} = live(conn, "/audio")
      view |> element("#milkdrop-ensure") |> render_click()
      assert_receive {:ensure_called, from}, 2_000

      Phoenix.PubSub.broadcast(
        @pubsub,
        MilkDrop.pack_topic(),
        {:milkdrop_pack_started, {:ready, "2026.12.0", "/x"}}
      )

      wait_until(fn -> render(view) =~ "Version 2026.12.0" end)

      GenServer.reply(from, {:error, :not_running})
      render_async(view)

      html = render(view)
      assert html =~ "Version 2026.12.0"
      refute html =~ "The visualizer service isn&#39;t running."
    end

    test "a stopped Pack reads as not running", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio")
      assert render(view) =~ "The visualizer service isn&#39;t running."
    end
  end

  describe "rotation interval" do
    setup %{root: root} do
      start_pack(root, nil)
      :ok
    end

    test "a change updates the Store", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio")

      view |> form("#milkdrop-rotate-form", %{rotate_s: "45"}) |> render_change()

      assert Store.settings().rotate_s == 45
      assert render(view) =~ "45 s"
    end

    test "an out-of-range or malformed value is refused without a write", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio")

      for bad <- ["5", "121", "abc", "30.5"] do
        html = view |> form("#milkdrop-rotate-form", %{rotate_s: bad}) |> render_change()
        assert html =~ "Rotation interval must be a whole number of seconds from 10 to 120."
      end

      assert Store.settings().rotate_s == 20

      view |> form("#milkdrop-rotate-form", %{rotate_s: "30"}) |> render_change()
      refute has_element?(view, "#milkdrop-error")
    end

    test "a change made elsewhere re-renders over PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio")

      {:ok, _} = Store.update(%{rotate_s: 90})
      wait_until(fn -> has_element?(view, "#milkdrop-rotate[value=\"90\"]") end)
      assert render(view) =~ "90 s"
    end

    test "a Store that can't write shows an inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio")
      stop_supervised!(Store)

      html = view |> form("#milkdrop-rotate-form", %{rotate_s: "45"}) |> render_change()

      assert html =~
               "Couldn&#39;t save the visualizer settings (the settings store isn&#39;t running)."
    end
  end

  describe "fast-flashing presets" do
    setup %{root: root} do
      start_pack(root, nil)
      :ok
    end

    test "turning on asks first, with the photosensitivity warning", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio")

      html = view |> element("#milkdrop-high-frequency") |> render_click()
      assert html =~ "Include fast-flashing presets?"

      assert html =~
               "These presets flash rapidly and may trigger seizures in people with photosensitive epilepsy."

      refute Store.settings().include_high_frequency
      refute toggle_checked?(view, "#milkdrop-high-frequency")

      view |> element("#milkdrop-confirm-high-frequency-button") |> render_click()

      assert Store.settings().include_high_frequency
      assert toggle_checked?(view, "#milkdrop-high-frequency")
      refute has_element?(view, "#milkdrop-confirm-high-frequency")
    end

    test "cancel leaves it off", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio")

      view |> element("#milkdrop-high-frequency") |> render_click()
      view |> element("#milkdrop-confirm-high-frequency button", "Cancel") |> render_click()

      refute has_element?(view, "#milkdrop-confirm-high-frequency")
      refute Store.settings().include_high_frequency
    end

    test "turning off needs no confirmation", %{conn: conn} do
      {:ok, _} = Store.update(%{include_high_frequency: true})
      {:ok, view, _html} = live(conn, "/audio")
      assert toggle_checked?(view, "#milkdrop-high-frequency")

      view |> element("#milkdrop-high-frequency") |> render_click()

      refute has_element?(view, "#milkdrop-confirm-high-frequency")
      refute Store.settings().include_high_frequency
      refute toggle_checked?(view, "#milkdrop-high-frequency")
    end
  end

  describe "skipped presets" do
    setup :ready_pack

    test "lists the ready version's skips with reasons, and clears them", %{conn: conn} do
      :ok = Store.skip(@version, "b/bright.milk", "too_bright")
      :ok = Store.skip(@version, "a/slow.milk", "budget")

      {:ok, view, _html} = live(conn, "/audio")
      assert view |> element("#milkdrop-skipped-count") |> render() =~ "2 skipped presets"
      refute has_element?(view, "#milkdrop-skipped-list")

      html = view |> element("#milkdrop-skipped-toggle") |> render_click()
      assert html =~ "a/slow.milk"
      assert html =~ "Too slow for this device"
      assert html =~ "b/bright.milk"
      assert html =~ "Too bright"
      assert html =~ "Cleared presets return from the next visualizer session."

      view |> element("#milkdrop-clear-skipped") |> render_click()

      assert Store.skipped(@version) == %{}
      assert view |> element("#milkdrop-skipped-count") |> render() =~ "No skipped presets"
      refute has_element?(view, "#milkdrop-clear-skipped")
    end

    test "a skip recorded while open re-renders over PubSub", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/audio")
      assert view |> element("#milkdrop-skipped-count") |> render() =~ "No skipped presets"

      :ok = Store.skip(@version, "c/broken.milk", "shader_error")
      wait_until(fn -> render(view) =~ "1 skipped preset" end)

      # The Store keeps one version: another version's skip replaces ours.
      :ok = Store.skip("2025.01.0", "d/other.milk", "budget")
      wait_until(fn -> render(view) =~ "No skipped presets" end)
      refute render(view) =~ "d/other.milk"
    end

    test "a Store that can't clear shows an inline error", %{conn: conn} do
      :ok = Store.skip(@version, "a/slow.milk", "budget")
      {:ok, view, _html} = live(conn, "/audio")
      stop_supervised!(Store)

      html = view |> element("#milkdrop-clear-skipped") |> render_click()
      assert html =~ "Couldn&#39;t clear skipped presets"
      assert html =~ "1 skipped preset"
    end
  end
end
