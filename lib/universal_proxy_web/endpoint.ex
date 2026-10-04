defmodule UniversalProxyWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :universal_proxy

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_universal_proxy_key",
    signing_salt: "jtTHK+Go",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [
      connect_info: [session: @session_options],
      # The device is reached via whatever name the user typed
      # (universal_proxy.local, nerves-xxxx.local, a bare IP), so no fixed
      # host list works. `:conn` accepts only an Origin whose scheme, host
      # and port match the request's own Host — i.e. the page this device
      # served — and rejects cross-site websocket hijacking from other
      # origins (Sobelow Config.CSWH).
      check_origin: :conn
    ],
    longpoll: false
  )

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug(Plug.Static,
    at: "/",
    from: :universal_proxy,
    gzip: false,
    only: UniversalProxyWeb.static_paths()
  )

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket("/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket)
    plug(Phoenix.LiveReloader)
    plug(Phoenix.CodeReloader)
  end

  plug(Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(UniversalProxyWeb.Router)
end
