defmodule UniversalProxyWeb.AudioLiveTest do
  @moduledoc """
  Exercises the `/audio` LiveView via PubSub-driven state mutation.

  The app-tree `Audio.Server` runs under `NullEnumerate` in test env
  (see `config/test.exs`) so `Audio.list_outputs/0` is always `[]` at
  mount time. We feed cards into the LiveView by broadcasting the same
  PubSub events `Audio.Server` would emit, which is exactly the
  contract the LiveView consumes in production.
  """

  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub

  @hp_key {"bcm2835 Headphones", nil, nil}

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp encode(key), do: key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  defp sample_output(overrides \\ %{}) do
    Map.merge(
      %{
        key: @hp_key,
        card_index: 0,
        alsa_device: "plughw:0,0",
        card_name: "bcm2835 Headphones",
        friendly_name: "Headphones",
        enabled: true,
        volume: 50,
        muted: false,
        client_id: "test-client-id"
      },
      overrides
    )
  end

  test "renders the empty state when no outputs are present", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/audio")
    assert html =~ "Sendspin players"
    assert html =~ "No audio outputs detected"
  end

  test "renders a card when a :sendspin_output_added event arrives", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    html = render(view)
    assert html =~ "Headphones"
    assert html =~ "plughw:0,0"
    assert html =~ "bcm2835 Headphones"
    # Default volume 50 should be in the readout next to the slider.
    assert html =~ ~s|name="value"|
    refute html =~ "No audio outputs detected"
  end

  test "removes the card when :sendspin_output_removed arrives", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    assert render(view) =~ "Headphones"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_removed",
      {:sendspin_output_removed, %{key: @hp_key}}
    )

    html = render(view)
    refute html =~ "Headphones"
    assert html =~ "No audio outputs detected"
  end

  test ":sendspin_state with stream_start updates the stream label", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    # Empty state for stream is the em-dash.
    assert render(view) =~ "—"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key,
       %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
    )

    html = render(view)
    assert html =~ "OPUS"
    assert html =~ "48 kHz"
    assert html =~ "16-bit"
  end

  test ":sendspin_state with friendly_name renames the card in place", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{friendly_name: "Living Room"}}
    )

    html = render(view)
    assert html =~ "Living Room"
    refute html =~ ~s|value="Headphones"|
  end

  test ":sendspin_state connection event flips the status badge", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    # Initial state: enabled + unknown connection → "Idle".
    assert render(view) =~ "Idle"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "connected"}}
    )

    assert render(view) =~ "Streaming"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "disconnected"}}
    )

    assert render(view) =~ "Searching"
  end

  test "rename event with empty name does not crash and does not put a flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    id = encode(@hp_key)

    # phx-blur on the name input fires `rename`. The form's hidden
    # `key` field provides the encoded id; the input's `name` field
    # provides the new name. We bypass the form element and render the
    # hook directly to avoid coupling to the form internals.
    html = render_hook(view, "rename", %{"key" => id, "name" => "   "})

    refute html =~ "Rename failed"
    # Original name unchanged.
    assert html =~ ~s|value="Headphones"|
  end

  test "rename event with invalid key id is silently ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    # Garbage id → decode fails → handler returns :noreply with no
    # flash, no crash.
    html = render_hook(view, "rename", %{"key" => "not-a-real-key", "name" => "Foo"})
    refute html =~ "Rename failed"
    assert html =~ "No audio outputs detected"
  end

  test "set_volume with a malformed value does not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    id = encode(@hp_key)

    # Non-integer "value" — handler falls through to :noreply.
    html = render_hook(view, "set_volume", %{"key" => id, "value" => "not-a-number"})
    assert html =~ "Headphones"
  end

  test "sorts output cards by friendly_name", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added,
       sample_output(%{key: {"vc4-hdmi", nil, nil}, friendly_name: "HDMI", card_name: "vc4-hdmi"})}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output(%{friendly_name: "Aux"})}
    )

    html = render(view)
    # "Aux" should appear before "HDMI" in the document order. Use the
    # byte offset as the ordering check.
    aux_pos = :binary.match(html, "Aux") |> elem(0)
    hdmi_pos = :binary.match(html, "HDMI") |> elem(0)
    assert aux_pos < hdmi_pos
  end
end
