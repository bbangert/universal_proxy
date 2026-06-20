defmodule UniversalProxyWeb.SecurityLiveTest do
  @moduledoc """
  Behavior for the Security tab. The API encryption card is connection-driven
  (plaintext until HA provisions a PSK, then encrypted); these tests drive the
  app-started global `PskStore` the way the SSH tests drive the real SSHAccess.
  The SSH access card download/copy actions are covered alongside.
  """

  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias UniversalProxy.ESPHome.PskStore
  alias UniversalProxy.SSHAccess

  @endpoint UniversalProxyWeb.Endpoint

  setup do
    # Start every test from a plaintext baseline on the global store.
    :ok = PskStore.clear()
    on_exit(fn -> PskStore.clear() end)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # --- API encryption card ---

  test "renders plaintext state when no key is provisioned", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/security")

    assert html =~ "API encryption"
    assert html =~ "Off"
    assert html =~ "turns on automatically"
    refute html =~ "Pre-shared key"
  end

  test "flips to encrypted live when HA provisions a key", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/security")

    key = :crypto.strong_rand_bytes(32)
    assert PskStore.store_psk(key) == :ok

    html = render(view)
    assert html =~ "Enforced"
    assert html =~ "Pre-shared key"
    assert html =~ Base.encode64(key)
  end

  test "Copy key pushes the base64 key and flips the label", %{conn: conn} do
    key = :crypto.strong_rand_bytes(32)
    :ok = PskStore.store_psk(key)

    {:ok, view, _html} = live(conn, "/security")

    html =
      view
      |> element("button[phx-click='copy_key']")
      |> render_click()

    assert_push_event(view, "copy", %{text: text})
    assert text == Base.encode64(key)
    assert html =~ "Copied"
  end

  test "Show toggles the key input between password and text", %{conn: conn} do
    :ok = PskStore.store_psk(:crypto.strong_rand_bytes(32))

    {:ok, view, html} = live(conn, "/security")
    assert html =~ ~s(type="password")

    shown = view |> element("button[phx-click='toggle_show_key']") |> render_click()
    assert shown =~ ~s(type="text")
  end

  test "Reset flow clears the key and returns to plaintext", %{conn: conn} do
    key = :crypto.strong_rand_bytes(32)
    :ok = PskStore.store_psk(key)

    {:ok, view, _html} = live(conn, "/security")

    modal = view |> element("button[phx-click='reset_request']") |> render_click()
    assert modal =~ "Reset API encryption?"

    html = view |> element("button[phx-click='confirm_reset']") |> render_click()
    assert html =~ "Encryption reset"
    assert html =~ "Off"
    refute html =~ "Pre-shared key"
    assert PskStore.load_psk() == nil
  end

  test "Cancel dismisses the reset modal and keeps the key", %{conn: conn} do
    key = :crypto.strong_rand_bytes(32)
    :ok = PskStore.store_psk(key)

    {:ok, view, _html} = live(conn, "/security")

    modal = view |> element("button[phx-click='reset_request']") |> render_click()
    assert modal =~ "Reset API encryption?"

    closed = view |> element("button[phx-click='cancel_reset']") |> render_click()
    refute closed =~ "Reset API encryption?"
    # Still encrypted — Cancel must not clear the key.
    assert closed =~ "Enforced"
    assert PskStore.load_psk() == key
  end

  # --- SSH access card (unchanged) ---

  test "renders the SSH access card with fingerprint and login command", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/security")

    assert html =~ "SSH access"
    assert html =~ "Access key fingerprint"
    assert html =~ SSHAccess.fingerprint()
    assert html =~ "ed25519"
    assert html =~ "ssh -i universal_proxy root@"
  end

  test "Download key pushes the private key as a download event", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/security")

    view
    |> element("button[phx-click='download_ssh_key']")
    |> render_click()

    assert_push_event(view, "download", %{content: content, filename: "universal_proxy"})
    assert content == SSHAccess.private_key()
    assert String.contains?(content, "BEGIN OPENSSH PRIVATE KEY")
  end

  test "Copy fingerprint pushes a copy event and flips the label", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/security")

    html =
      view
      |> element("button[phx-click='copy_fingerprint']")
      |> render_click()

    assert_push_event(view, "copy", %{text: text})
    assert text == SSHAccess.fingerprint()
    assert html =~ "Copied"
  end
end
