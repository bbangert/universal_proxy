defmodule UniversalProxyWeb.Components.UIModalTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias UniversalProxyWeb.Components.UI

  defp render_modal(attrs) do
    assigns = Map.merge(%{open: true, on_close: "cancel_thing", title: "Do the thing?"}, attrs)

    html =
      rendered_to_string(~H"""
      <UI.modal {assigns}>
        <p>Body text</p>
        <:footer><button type="button">Cancel</button></:footer>
      </UI.modal>
      """)

    {html, LazyHTML.from_fragment(html)}
  end

  defp attr!(doc, selector, name) do
    [value] = doc |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
    value
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  test "a closed modal renders nothing" do
    {html, _doc} = render_modal(%{open: false})
    assert String.trim(html) == ""
  end

  test "dialog semantics, labelled by the title and described by subtitle and body" do
    {_html, doc} = render_modal(%{subtitle: "It can't be undone."})

    dialog = "#modal-cancel_thing-content"
    assert attr!(doc, dialog, "role") == "dialog"
    assert attr!(doc, dialog, "aria-modal") == "true"

    title_id = attr!(doc, dialog, "aria-labelledby")
    assert doc |> LazyHTML.query("h3##{title_id}") |> LazyHTML.text() == "Do the thing?"

    ids = doc |> attr!(dialog, "aria-describedby") |> String.split()
    assert ids == ["modal-cancel_thing-subtitle", "modal-cancel_thing-body"]
    for id <- ids, do: assert(count(doc, "##{id}") == 1)
  end

  test "focus is contained, moved in on open and restored on close" do
    {_html, doc} = render_modal(%{})

    # focus_wrap/1: its hook and the two tab sentinels.
    assert attr!(doc, "#modal-cancel_thing-content", "phx-hook") == "Phoenix.FocusWrap"
    assert count(doc, "#modal-cancel_thing-content-start[tabindex='0']") == 1
    assert count(doc, "#modal-cancel_thing-content-end[tabindex='0']") == 1

    on_open = attr!(doc, "#modal-cancel_thing", "phx-mounted")
    assert on_open =~ "push_focus"
    assert on_open =~ ~s("focus_first")
    assert on_open =~ "#modal-cancel_thing-content"
    assert attr!(doc, "#modal-cancel_thing", "phx-remove") =~ "pop_focus"
  end

  test "return_focus focuses a selector on close instead of the opener" do
    {_html, doc} = render_modal(%{return_focus: "#picker", id: "my-modal"})

    on_open = attr!(doc, "#my-modal", "phx-mounted")
    refute on_open =~ "push_focus"
    assert on_open =~ "#my-modal-content"

    on_remove = attr!(doc, "#my-modal", "phx-remove")
    assert on_remove =~ ~s("focus")
    assert on_remove =~ "#picker"
    refute on_remove =~ "pop_focus"
  end

  test "Escape and the backdrop close through on_close, on the given target" do
    {_html, doc} = render_modal(%{target: "#some-component"})

    assert attr!(doc, "#modal-cancel_thing", "phx-window-keydown") == "cancel_thing"
    assert attr!(doc, "#modal-cancel_thing", "phx-key") == "escape"
    assert attr!(doc, "#modal-cancel_thing", "phx-target") == "#some-component"
    assert count(doc, "#modal-cancel_thing > div[phx-click='cancel_thing']") == 1
  end
end
