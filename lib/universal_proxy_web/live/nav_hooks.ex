defmodule UniversalProxyWeb.NavHooks do
  @moduledoc """
  LiveView on_mount hook for cross-cutting app-shell state:

    * `:current_path` — so the app layout can highlight the active tab.
    * `:ha_clients` / `:ha_open` — the connected ESPHome native-API clients
      shown in the header pill, plus its popover open state. Maintained for
      every LiveView so the shared layout pill works on every tab.

  The pill reconciles the live client set on mount (`Clients.list/0`, the
  source of truth) and again whenever `ESPHome.Clients` broadcasts a change,
  so a connect/disconnect that happened before this LiveView mounted is never
  missed. The popover open/close + refresh-on-open are handled here via
  attached event hooks, so individual LiveViews need no extra code.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias UniversalProxy.ESPHome.Clients

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(UniversalProxy.PubSub, Clients.topic())
    end

    socket =
      socket
      # Cheap default on the dead (HTTP) render; populated after the socket
      # connects and we've subscribed, then kept fresh by the info hook below.
      |> assign(:ha_clients, if(connected?(socket), do: Clients.list(), else: []))
      |> assign(:ha_open, false)
      |> attach_hook(:set_current_path, :handle_params, fn _params, uri, socket ->
        %URI{path: path} = URI.parse(uri)
        {:cont, assign(socket, :current_path, path)}
      end)
      |> attach_hook(:ha_clients_info, :handle_info, &handle_clients_info/2)
      |> attach_hook(:ha_clients_event, :handle_event, &handle_clients_event/3)

    {:cont, socket}
  end

  # Reserved across all LiveViews in this live_session: the `:esphome_clients_changed`
  # message and the `toggle_ha_clients` / `close_ha_clients` events are intercepted
  # here (`:halt`) and never reach a LiveView's own handlers. Don't reuse those names.
  defp handle_clients_info(:esphome_clients_changed, socket) do
    {:halt, assign(socket, :ha_clients, Clients.list())}
  end

  defp handle_clients_info(_msg, socket), do: {:cont, socket}

  # Opening also re-reads the live set so durations / last-packet are fresh.
  defp handle_clients_event("toggle_ha_clients", _params, socket) do
    open? = !socket.assigns.ha_open

    socket =
      socket
      |> assign(:ha_open, open?)
      |> then(fn s -> if open?, do: assign(s, :ha_clients, Clients.list()), else: s end)

    {:halt, socket}
  end

  defp handle_clients_event("close_ha_clients", _params, socket) do
    {:halt, assign(socket, :ha_open, false)}
  end

  defp handle_clients_event(_event, _params, socket), do: {:cont, socket}
end
