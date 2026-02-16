defmodule UniversalProxy.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Start the Telemetry supervisor
        UniversalProxyWeb.Telemetry,
        # Start the PubSub system
        {Phoenix.PubSub, name: UniversalProxy.PubSub},
        # Start the Endpoint (http/https)
        UniversalProxyWeb.Endpoint,
        # Start the UART subsystem (DynamicSupervisor + registry server)
        UniversalProxy.UART.Supervisor,
        # Start the ESPHome Native API subsystem (TCP server + connections)
        UniversalProxy.ESPHome.Supervisor
      ] ++ target_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: UniversalProxy.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # List all child processes to be supervised
  defp target_children do
    [
      # Children for all targets
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    UniversalProxyWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
