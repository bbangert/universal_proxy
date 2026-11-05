defmodule UniversalProxy.Display.TextFitTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.TextFit

  test "text that fits is unchanged" do
    assert TextFit.fit("Short", 1000, 40) == "Short"
    assert TextFit.fit("", 10, 40) == ""
  end

  test "cuts long text to the width and ends it with an ellipsis" do
    text = String.duplicate("Lorem ipsum dolor sit amet ", 10)
    fitted = TextFit.fit(text, 600, 40)

    assert String.ends_with?(fitted, "…")
    refute String.ends_with?(fitted, " …")
    assert TextFit.em_width(fitted) * 40 <= 600
    assert String.starts_with?(text, String.trim_trailing(fitted, "…"))
  end

  test "bold text gets fewer characters" do
    text = String.duplicate("abcdefgh", 20)

    assert String.length(TextFit.fit(text, 500, 40, true)) <
             String.length(TextFit.fit(text, 500, 40))
  end

  test "wide characters count a full em; graphemes are never split" do
    assert TextFit.fit("日本語のタイトル", 4 * 40, 40) |> String.length() <= 4
    fitted = TextFit.fit(String.duplicate("é", 50), 200, 40)
    assert String.valid?(fitted) and String.ends_with?(fitted, "…")
  end
end
