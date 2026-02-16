defmodule UniversalProxyWeb.NavHooks do
  @moduledoc """
  LiveView on_mount hook that assigns the current request path
  so the app layout can highlight the active navigation tab.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     socket
     |> attach_hook(:set_current_path, :handle_params, fn _params, uri, socket ->
       %URI{path: path} = URI.parse(uri)
       {:cont, assign(socket, :current_path, path)}
     end)}
  end
end
