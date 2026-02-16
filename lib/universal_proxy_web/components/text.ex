defmodule UniversalProxyWeb.Components.Text do
  use Phoenix.Component

  attr :title, :string, required: true

  def page_title(assigns) do
    ~H"""
    <h1 class="text-3xl font-bold text-zinc-900 dark:neon-text dark:text-neon-purple font-mono">
      {@title}
    </h1>
    """
  end

  slot :inner_block, required: true

  def body(assigns) do
    ~H"""
    <p class="mt-4 text-zinc-600 dark:text-zinc-400 dark:text-zinc-300">
      <%= render_slot(@inner_block) %>
    </p>
    """
  end

  attr :href, :string, required: true
  slot :inner_block, required: true

  def link_to(assigns) do
    ~H"""
    <a href={@href} class="text-brand hover:underline dark:text-neon-purple dark:neon-link" target="_blank" rel="noopener noreferrer">
      <%= render_slot(@inner_block) %>
    </a>
    """
  end
end
