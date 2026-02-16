defmodule UniversalProxyWeb.HomeLive do
  use UniversalProxyWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <.page_title title="Home" />
    </div>
    """
  end
end
