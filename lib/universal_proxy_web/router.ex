defmodule UniversalProxyWeb.Router do
  use UniversalProxyWeb, :router

  # Sobelow's Config.CSP only recognises a static policy passed to
  # put_secure_browser_headers; this pipeline sets a per-request
  # (nonce-bearing) policy in put_content_security_policy/2 below, which the
  # static check can't see. Covered by test/universal_proxy_web/csp_test.exs.
  # sobelow_skip ["Config.CSP"]
  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {UniversalProxyWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(:put_content_security_policy)
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  scope "/", UniversalProxyWeb do
    pipe_through(:browser)

    live_session :default, on_mount: [UniversalProxyWeb.NavHooks] do
      live("/", OverviewLive)
      live("/traffic", TrafficLive)
      live("/audio", AudioLive)
      live("/bluetooth", BluetoothLive)
      live("/discovery", DiscoveryLive)
      live("/security", SecurityLive)
      live("/system", SystemLive)
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", UniversalProxyWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:universal_proxy, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through(:browser)

      # Script nonce only: a style nonce would make browsers ignore the
      # policy's 'unsafe-inline' for styles (see put_content_security_policy/2).
      live_dashboard("/dashboard",
        metrics: UniversalProxyWeb.Telemetry,
        csp_nonce_assign_key: %{script: :csp_nonce}
      )
    end
  end

  @doc """
  Sets a per-request `content-security-policy` header and assigns the
  matching script nonce as `:csp_nonce`.

  Scripts are limited to same-origin files plus inline `<script nonce=...>`
  blocks (the root layout's pre-paint theme script, LiveDashboard's
  bootstrap). Styles keep `'unsafe-inline'` because LiveView patches
  server-rendered `style="..."` attributes into the DOM; for that reason no
  style nonce is issued (a nonce would make browsers ignore
  `'unsafe-inline'`). `connect-src 'self'` covers the same-origin LiveView
  websocket; `blob:` URLs are only used for same-page downloads.
  """
  def put_content_security_policy(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    policy =
      Enum.join(
        [
          "default-src 'self'",
          "script-src 'self' 'nonce-#{nonce}'",
          "style-src 'self' 'unsafe-inline'",
          "img-src 'self' data: blob:",
          "font-src 'self'",
          "connect-src 'self'",
          "object-src 'none'",
          "base-uri 'self'",
          "form-action 'self'",
          "frame-ancestors 'self'"
        ],
        "; "
      )

    conn
    |> Plug.Conn.assign(:csp_nonce, nonce)
    |> Plug.Conn.put_resp_header("content-security-policy", policy)
  end
end
