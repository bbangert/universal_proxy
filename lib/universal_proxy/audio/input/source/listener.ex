defmodule UniversalProxy.Audio.Input.Source.Listener do
  @moduledoc """
  The one-route `Plug` behind each capture card's Sendspin websocket
  listener.

  Music Assistant discovers our `_sendspin._tcp` advertisement and dials
  `ws://<host>:<port><path>`, where `path` comes from the mDNS TXT `path`
  key. `path` is fixed to `/sendspin` in aiosendspin
  (`aiosendspin/server/server.py`, `API_PATH = "/sendspin"  # Fixed by
  protocol`), so that is what we serve and what the mDNS layer must
  advertise — see `UniversalProxy.Audio.Input.Source.default_path/0`.

  Anything that is not a websocket upgrade of that exact path gets a bare
  404: the listener exists solely to accept one MA connection per capture
  card, and `WebSockAdapter.upgrade/4` raises on a non-upgrade request, so
  the shape check happens here rather than in the adapter.
  """

  @behaviour Plug

  alias UniversalProxy.Audio.Input.Source.Socket

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    path = Keyword.fetch!(opts, :path)
    source = Keyword.fetch!(opts, :source)

    if conn.request_path == path and websocket_upgrade?(conn) do
      conn
      |> WebSockAdapter.upgrade(Socket, [source: source], Keyword.get(opts, :websock_opts, []))
      |> Plug.Conn.halt()
    else
      conn
      |> Plug.Conn.send_resp(404, "not found")
      |> Plug.Conn.halt()
    end
  end

  # RFC 6455 §4.2.1: the `Upgrade` header is a comma-separated, case-
  # insensitive token list. Cowboy lowercases header names but not values.
  defp websocket_upgrade?(conn) do
    conn
    |> Plug.Conn.get_req_header("upgrade")
    |> Enum.any?(fn value ->
      value
      |> String.downcase()
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.member?("websocket")
    end)
  end
end
