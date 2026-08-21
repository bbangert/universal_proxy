defmodule UniversalProxyWeb.Layouts do
  use UniversalProxyWeb, :html

  import UniversalProxyWeb.Components.UI

  embed_templates("layouts/*")

  @doc "A single tab link in the top tab strip."
  attr(:path, :string, required: true)
  attr(:current, :string, required: true)
  attr(:label, :string, required: true)

  def tab(assigns) do
    active = assigns.current == assigns.path
    assigns = assign(assigns, :active, active)

    ~H"""
    <.link
      navigate={@path}
      class={[
        "px-3.5 py-3.5 text-sm font-medium border-b-2 -mb-px transition-colors",
        if(@active,
          do: "text-accent border-accent",
          else: "text-fg-2 border-transparent hover:text-fg-1"
        )
      ]}
    >
      {@label}
    </.link>
    """
  end

  @doc "Render flash messages."
  attr(:flash, :map, required: true)

  def flash_group(assigns) do
    ~H"""
    <div :if={Phoenix.Flash.get(@flash, :info) || Phoenix.Flash.get(@flash, :error)} class="px-6 pt-4">
      <div
        :if={msg = Phoenix.Flash.get(@flash, :info)}
        id="flash-info"
        class="rounded-md bg-success-soft text-success px-3.5 py-2.5 text-sm flex items-center gap-2"
        phx-click="lv:clear-flash"
        phx-value-key="info"
        phx-hook="AutoDismissFlash"
        data-timeout="4000"
        role="status"
        tabindex="0"
      >
        {msg}
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :error)}
        id="flash-error"
        class="rounded-md bg-danger-soft text-danger px-3.5 py-2.5 text-sm flex items-center gap-2 mt-2"
        phx-click="lv:clear-flash"
        phx-value-key="error"
        phx-hook="AutoDismissFlash"
        data-timeout="8000"
        role="alert"
        tabindex="0"
      >
        {msg}
      </div>
    </div>
    """
  end
end
