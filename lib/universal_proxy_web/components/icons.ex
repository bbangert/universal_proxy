defmodule UniversalProxyWeb.Components.Icons do
  @moduledoc "Inline SVG icons used across the UI."

  use Phoenix.Component

  attr(:name, :atom, required: true)
  attr(:size, :integer, default: 20)
  attr(:stroke, :float, default: 1.6)
  attr(:class, :string, default: nil)

  def icon(assigns) do
    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width={@stroke}
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
    >
      {paths(@name)}
    </svg>
    """
  end

  defp paths(:plug) do
    assigns = %{}

    ~H"""
    <path d="M9 2v4M15 2v4M6 9V6h12v3a6 6 0 0 1-12 0zM12 15v7" />
    """
  end

  defp paths(:refresh) do
    assigns = %{}

    ~H"""
    <path d="M21 12a9 9 0 1 1-3-6.7L21 8" />
    <path d="M21 3v5h-5" />
    """
  end

  defp paths(:check) do
    assigns = %{}

    ~H"""
    <path d="M5 12l5 5 9-11" />
    """
  end

  defp paths(:x) do
    assigns = %{}

    ~H"""
    <path d="M18 6L6 18M6 6l12 12" />
    """
  end

  defp paths(:settings) do
    assigns = %{}

    ~H"""
    <circle cx="12" cy="12" r="3" />
    <path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 0 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 0 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 0 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 0 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z" />
    """
  end

  defp paths(:download) do
    assigns = %{}

    ~H"""
    <path d="M12 4v12M7 11l5 5 5-5M4 20h16" />
    """
  end

  defp paths(:logs) do
    assigns = %{}

    ~H"""
    <path d="M4 4h14l2 2v14H4z" />
    <path d="M8 10h8M8 14h8M8 18h5" />
    """
  end

  defp paths(:lock) do
    assigns = %{}

    ~H"""
    <rect x="4" y="11" width="16" height="10" rx="2" />
    <path d="M8 11V7a4 4 0 0 1 8 0v4" />
    """
  end

  defp paths(:info) do
    assigns = %{}

    ~H"""
    <circle cx="12" cy="12" r="10" />
    <path d="M12 16v-4M12 8h.01" />
    """
  end

  defp paths(:alert) do
    assigns = %{}

    ~H"""
    <circle cx="12" cy="12" r="10" />
    <path d="M12 8v4M12 16h.01" />
    """
  end

  defp paths(:play) do
    assigns = %{}

    ~H"""
    <path d="M6 4l14 8-14 8V4z" />
    """
  end

  defp paths(:pause) do
    assigns = %{}

    ~H"""
    <rect x="6" y="4" width="4" height="16" />
    <rect x="14" y="4" width="4" height="16" />
    """
  end

  defp paths(:chevron) do
    assigns = %{}

    ~H"""
    <path d="M6 9l6 6 6-6" />
    """
  end

  defp paths(:sun) do
    assigns = %{}

    ~H"""
    <circle cx="12" cy="12" r="4" />
    <path d="M12 2v2M12 20v2M4.93 4.93l1.41 1.41M17.66 17.66l1.41 1.41M2 12h2M20 12h2M4.93 19.07l1.41-1.41M17.66 6.34l1.41-1.41" />
    """
  end

  defp paths(:moon) do
    assigns = %{}

    ~H"""
    <path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z" />
    """
  end

  defp paths(:auto_theme) do
    assigns = %{}

    ~H"""
    <circle cx="12" cy="12" r="9" />
    <path d="M12 3a9 9 0 0 1 0 18z" fill="currentColor" stroke="none" />
    """
  end

  # Port-kind glyphs (drawn separately from outline icons since they have
  # mixed fills/strokes and meaningful color tints).
  attr(:kind, :atom, required: true)
  attr(:size, :integer, default: 20)

  def port_glyph(assigns) do
    ~H"""
    <svg width={@size} height={@size} viewBox="0 0 24 24">
      {kind_glyph(@kind)}
    </svg>
    """
  end

  defp kind_glyph(:zwave) do
    assigns = %{}

    ~H"""
    <path
      d="M3 15a9 9 0 0 1 18 0M6.5 15a5.5 5.5 0 0 1 11 0M10 15a2 2 0 0 1 4 0"
      stroke="currentColor"
      stroke-width="1.6"
      fill="none"
      stroke-linecap="round"
    />
    """
  end

  defp kind_glyph(:ir) do
    assigns = %{}

    ~H"""
    <circle cx="12" cy="12" r="2" fill="currentColor" />
    <path
      d="M7 12a5 5 0 0 1 10 0M4 12a8 8 0 0 1 16 0"
      stroke="currentColor"
      stroke-width="1.6"
      fill="none"
      stroke-linecap="round"
    />
    """
  end

  defp kind_glyph(:rs232) do
    assigns = %{}

    ~H"""
    <rect x="3" y="8" width="18" height="8" rx="2" stroke="currentColor" stroke-width="1.6" fill="none" />
    <path
      d="M7 12h.01M10 12h.01M13 12h.01M16 12h.01"
      stroke="currentColor"
      stroke-width="2"
      stroke-linecap="round"
    />
    """
  end

  defp kind_glyph(:rs485) do
    assigns = %{}

    ~H"""
    <rect x="3" y="9" width="18" height="6" rx="1.5" stroke="currentColor" stroke-width="1.6" fill="none" />
    <path
      d="M8 6v3M16 6v3M8 15v3M16 15v3"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
    />
    """
  end

  defp kind_glyph(:ttl) do
    assigns = %{}

    ~H"""
    <path
      d="M4 8v8M8 8v8M12 8v8M16 8v8M20 8v8"
      stroke="currentColor"
      stroke-width="1.6"
      stroke-linecap="round"
    />
    """
  end

  defp kind_glyph(_) do
    assigns = %{}

    ~H"""
    <circle cx="12" cy="12" r="3" stroke="currentColor" stroke-width="1.6" fill="none" />
    """
  end
end
