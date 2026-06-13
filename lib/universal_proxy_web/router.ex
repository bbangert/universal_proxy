defmodule UniversalProxyWeb.Router do
  use UniversalProxyWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, {UniversalProxyWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
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

      live_dashboard("/dashboard", metrics: UniversalProxyWeb.Telemetry)
    end
  end
end
