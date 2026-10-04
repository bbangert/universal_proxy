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
    # Overview's FMA120/BTD 700 shape checks pin only the VID/PID, so the
    # slot element is unconstrained: a fun nested there passes the shape
    # check and was accepted by plain `binary_to_term(bin, [:safe])`.
    # (AudioLive's valid_key_shape?/1 requires binary/integer/nil elements,
    # so no fun can reach it there.)
    @fma120_vid 0x0A12
    @fma120_pid 0x4007

    defp enc(key), do: key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

    test "a well-formed FMA120 key opens the drawer (control)" do
      {:ok, view, _html} = live(build_conn(), "/")

      html =
        render_click(view, "select_fma120", %{"key" => enc({"1-1.3", @fma120_vid, @fma120_pid})})

      assert html =~ "close_fma120_drawer"
    end

    test "a fun nested in an otherwise valid FMA120 key is rejected" do
      {:ok, view, _html} = live(build_conn(), "/")
      key = enc({fn -> :executed end, @fma120_vid, @fma120_pid})
      # Must fit the decoder's 256-byte cap, or the size check (not the
      # non-executable decode) would be what rejects it.
      assert byte_size(Base.url_decode64!(key, padding: false)) <= 256

      html = render_click(view, "select_fma120", %{"key" => key})
      refute html =~ "close_fma120_drawer"
    end
  end
end
