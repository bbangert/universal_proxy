defmodule UniversalProxyWeb.SecurityLiveTest do
  @moduledoc """
  Behavior for the SSH access card added to the Security tab. The full-render
  smoke check lives in [render_smoke_test.exs](render_smoke_test.exs); this
  file focuses on the SSH key download/copy actions.
  """

  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias UniversalProxy.SSHAccess

  @endpoint UniversalProxyWeb.Endpoint

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

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
