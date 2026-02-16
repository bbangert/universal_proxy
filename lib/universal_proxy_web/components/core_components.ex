defmodule UniversalProxyWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.
  """
  use Phoenix.Component

  @doc """
  Renders a [Hero Icon](https://heroicons.com).
  Icons are loaded from the heroicons dependency when available.
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil

  def icon(assigns) do
    ~H"""
    <span class={["inline-block", @class]} data-icon={@name}></span>
    """
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(UniversalProxyWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(UniversalProxyWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
