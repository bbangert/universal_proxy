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

    # A key that is well-formed in every way except that its ETF is
    # compressed. The long, repetitive slot makes `compressed: 6` actually
    # emit the compressed form (it falls back to plain ETF when that's
    # smaller), while the plain form still fits under the 256-byte cap.
    defp compressed_enc(key) do
      bin = :erlang.term_to_binary(key, compressed: 6)
      assert <<131, 80, _::binary>> = bin
      assert byte_size(:erlang.term_to_binary(key)) <= 256
      Base.url_encode64(bin, padding: false)
    end

    defp long_slot(n), do: String.duplicate("a", n)

    defp select_fma120(key) do
      {:ok, view, _html} = live(build_conn(), "/")
      render_click(view, "select_fma120", %{"key" => key})
    end

    test "a well-formed FMA120 key opens the drawer (control)" do
      assert select_fma120(enc({"1-1.3", @fma120_vid, @fma120_pid})) =~ "close_fma120_drawer"

      assert select_fma120(enc({long_slot(200), @fma120_vid, @fma120_pid})) =~
               "close_fma120_drawer"
    end

    test "a fun nested in an otherwise valid FMA120 key is rejected" do
      key = enc({fn -> :executed end, @fma120_vid, @fma120_pid})
      # Must fit the decoder's 256-byte cap, or the size check (not the
      # non-executable decode) would be what rejects it.
      assert byte_size(Base.url_decode64!(key, padding: false)) <= 256

      refute select_fma120(key) =~ "close_fma120_drawer"
    end

    test "a compressed FMA120 key is rejected" do
      key = compressed_enc({long_slot(200), @fma120_vid, @fma120_pid})
      refute select_fma120(key) =~ "close_fma120_drawer"
    end

    test "an oversized FMA120 key is rejected" do
      refute select_fma120(enc({long_slot(300), @fma120_vid, @fma120_pid})) =~
               "close_fma120_drawer"
    end

    # AudioLive's set_volume decodes the key and calls Audio.update_config/2;
    # in test env the server tracks no outputs, so a key that *decodes*
    # yields a logged {:error, :not_found}, and a rejected key logs nothing.
    defp audio_set_volume_log(key) do
      {:ok, view, _html} = live(build_conn(), "/audio")

      ExUnit.CaptureLog.capture_log(fn ->
        render_hook(view, "set_volume", %{"key" => key, "value" => "50"})
      end)
    end

    test "a well-formed Audio key is decoded (control)" do
      assert audio_set_volume_log(enc({long_slot(200), nil, nil})) =~ "set_volume failed"
    end

    test "a compressed Audio key is rejected" do
      refute audio_set_volume_log(compressed_enc({long_slot(200), nil, nil})) =~
               "set_volume failed"
    end

    test "an oversized Audio key is rejected" do
      refute audio_set_volume_log(enc({long_slot(300), nil, nil})) =~ "set_volume failed"
    end
  end

  describe "UniversalProxyWeb.OpaqueKey" do
    alias UniversalProxyWeb.OpaqueKey

    test "round-trips encode/1" do
      key = {"1-1.3", 0x0A12, 0x4007}
      assert {:ok, ^key} = key |> OpaqueKey.encode() |> OpaqueKey.decode()
    end

    test "rejects garbage, non-binaries, bad ETF, compressed, oversized and funs" do
      assert :error = OpaqueKey.decode("not base64!")
      assert :error = OpaqueKey.decode(nil)
      assert :error = OpaqueKey.decode(Base.url_encode64(<<131, 255>>, padding: false))
      assert :error = OpaqueKey.decode(Base.url_encode64(<<1, 2, 3>>, padding: false))

      big = {String.duplicate("a", 200), 1, 2}

      assert :error =
               big
               |> :erlang.term_to_binary(compressed: 6)
               |> Base.url_encode64(padding: false)
               |> OpaqueKey.decode()

      assert :error = OpaqueKey.decode(OpaqueKey.encode({String.duplicate("a", 300), 1, 2}))
      assert :error = OpaqueKey.decode(OpaqueKey.encode({fn -> :x end, 1, 2}))
    end
  end
end
