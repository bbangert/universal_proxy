defmodule UniversalProxyWeb.WebSecurityTest do
  @moduledoc """
  Guards the web-layer hardening that Sobelow checks for: the per-request
  Content-Security-Policy, the LiveView socket's origin check, and the
  non-executable decoding of opaque LiveView keys.
  """
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint UniversalProxyWeb.Endpoint

  describe "content-security-policy" do
    test "browser pages carry a nonce-based policy that the inline script uses" do
      conn = get(build_conn(), "/")
      [policy] = Plug.Conn.get_resp_header(conn, "content-security-policy")

      assert policy =~ "default-src 'self'"
      assert policy =~ "object-src 'none'"
      assert policy =~ "frame-ancestors 'self'"
      refute policy =~ "unsafe-eval"

      [_, nonce] = Regex.run(~r/script-src 'self' 'nonce-([^']+)'/, policy)
      refute Regex.match?(~r/script-src[^;]*'unsafe-inline'/, policy)
      assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce}">)
    end

    test "the nonce is fresh on every request" do
      nonce = fn ->
        [policy] =
          build_conn() |> get("/") |> Plug.Conn.get_resp_header("content-security-policy")

        Regex.run(~r/'nonce-([^']+)'/, policy, capture: :all_but_first)
      end

      refute nonce.() == nonce.()
    end
  end

  describe "LiveView socket origin check" do
    setup do
      {_path, _mod, opts} =
        Enum.find(UniversalProxyWeb.Endpoint.__sockets__(), fn {path, _, _} -> path == "/live" end)

      {:ok, ws_opts: Keyword.fetch!(opts, :websocket)}
    end

    defp check(origin, ws_opts) do
      build_conn(:get, "http://universal_proxy.local/live/websocket")
      |> Plug.Conn.put_req_header("origin", origin)
      |> Phoenix.Socket.Transport.check_origin(
        Phoenix.LiveView.Socket,
        UniversalProxyWeb.Endpoint,
        ws_opts,
        & &1
      )
    end

    test "accepts the origin the page was served from", %{ws_opts: ws_opts} do
      refute check("http://universal_proxy.local", ws_opts).halted
    end

    @tag capture_log: true
    test "rejects a cross-site origin", %{ws_opts: ws_opts} do
      conn = check("http://evil.example", ws_opts)
      assert conn.halted
      assert conn.status == 403
    end
  end

  describe "opaque key decoding" do
    test "an encoded fun is rejected without crashing the LiveView" do
      {:ok, view, _html} = live(build_conn(), "/audio")
      fun = fn -> send(self(), :executed) end
      id = fun |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

      render_hook(view, "allow_pairing", %{"id" => id})
      render_hook(view, "toggle_mute", %{"id" => id})

      assert render(view) =~ "Sendspin players"
      refute_received :executed
    end
  end
end
