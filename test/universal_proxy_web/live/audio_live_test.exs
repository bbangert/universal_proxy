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
  import UniversalProxy.AudioFixtures

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub

  @hp_key UniversalProxy.AudioFixtures.hp_key()

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp encode(key), do: key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

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

  test ":sendspin_state events flip the status badge through its states", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    # Initial state: enabled + unknown connection → "Idle".
    assert render(view) =~ "Idle"

    # `connected` alone — WebSocket is up but the server hasn't pushed a
    # stream yet. Badge reads "Connected", NOT "Streaming". The
    # Sendspin client holds the socket open between songs, so this is
    # the long-lived idle-but-attached state.
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "connected"}}
    )

    html = render(view)
    assert html =~ "Connected"
    refute html =~ ">Streaming<"

    # `stream_start` flips to "Streaming".
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key,
       %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
    )

    assert render(view) =~ "Streaming"

    # `stream_end` while still connected drops back to "Connected", not
    # "Streaming" — the bug PR fixes. Server is still reachable, just
    # not pushing audio.
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "stream_end"}}
    )

    html = render(view)
    assert html =~ "Connected"
    refute html =~ ">Streaming<"

    # Then `disconnected` — server reachability lost.
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

  test ":sendspin_state with stream_end clears the stream label", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key,
       %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
    )

    assert render(view) =~ "OPUS"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "stream_end"}}
    )

    html = render(view)
    refute html =~ "OPUS"
    refute html =~ "48 kHz"
  end

  test ":sendspin_state with error event renders last_error in the card", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "error", msg: "ALSA open failed"}}
    )

    assert render(view) =~ "ALSA open failed"
  end

  test ":sendspin_state with shutdown event clears connection and stream", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "connected"}}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key,
       %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
    )

    assert render(view) =~ "Streaming"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "shutdown"}}
    )

    html = render(view)
    refute html =~ "Streaming"
    refute html =~ "OPUS"
    assert html =~ "Searching"
  end

  test "renders the Disabled badge when an output is not enabled", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output(%{enabled: false})}
    )

    html = render(view)
    assert html =~ "Disabled"
    refute html =~ ">Streaming<"
    refute html =~ ">Idle<"
  end

  test "rename with all-control-chars name is silently dropped (no flash, no dispatch)",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    id = encode(@hp_key)

    # `~r/[[:cntrl:]]/u` in `sanitize_friendly_name/1` strips control
    # chars first, then trim. An all-cntrl input strips to "" → handler
    # short-circuits with `{:error, :empty_name}` and returns `{:noreply,
    # socket}` WITHOUT calling `Audio.update_config` and WITHOUT putting
    # a flash. (A non-empty post-strip would dispatch and the app-tree
    # Server's `{:error, :not_found}` would surface as a flash — that's
    # the natural code path, not the property under test here.)
    html = render_hook(view, "rename", %{"key" => id, "name" => "\t\n\v\r"})

    refute html =~ "Rename failed"
    # Original name unchanged.
    assert html =~ ~s|value="Headphones"|
  end

  test "rename rejects correctly-encoded but wrong-shape keys", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    # A valid base64 of a valid Erlang term that isn't a 3-tuple. The
    # shape guard in `valid_key_shape?/1` must reject this so a
    # tampered DOM param can't reach `update_config/2`.
    bad_id = :not_a_key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

    html = render_hook(view, "rename", %{"key" => bad_id, "name" => "X"})

    refute html =~ "Rename failed"
    assert html =~ "No audio outputs detected"
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
