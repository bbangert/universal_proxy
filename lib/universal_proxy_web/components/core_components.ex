defmodule UniversalProxyWeb.CoreComponents do
  @moduledoc """
  Provides core UI components — currently only error-translation helpers.
  Visual primitives live in `UniversalProxyWeb.Components.UI` and inline
  SVG icons in `UniversalProxyWeb.Components.Icons`.
  """

  use Phoenix.Component

  @doc "Translates an error message using gettext."
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(UniversalProxyWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(UniversalProxyWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc "Translates the errors for a field from a keyword list of errors."
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
