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

    # The redesigned card surfaces the codec/rate/depth label inside the
    # stream banner — which only renders the codec text when both
    # `:connected` AND a stream snapshot are present. The real binary
    # always emits `connected` before `stream_start`, so we mirror that
    # ordering here.
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
    # The card_name sub-line ("bcm2835 Headphones") still contains the
    # substring "Headphones" — that's the underlying ALSA card name,
    # which a rename doesn't change. Assert specifically that the
    # friendly_name button no longer renders the old value.
    refute html =~ ">Headphones<"
  end

  test ":sendspin_state events flip the status badge through its states", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    # Initial state: enabled + no event yet → "Searching". The redesign
    # collapses the original "Idle vs Stopped" split between
    # AudioLive and OverviewLive into one shared vocabulary
    # (Streaming / Connected / Searching / Disabled).
    assert render(view) =~ "Searching"

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

  test "confirm_rename with empty draft is a soft cancel — no flash, no dispatch", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    id = encode(@hp_key)

    # Open the modal, then submit an all-whitespace draft. The
    # post-clean string is empty, so `confirm_rename` short-circuits to
    # close without calling `Audio.update_config` or putting a flash.
    _ = render_hook(view, "open_rename", %{"id" => id})
    _ = render_hook(view, "rename_draft", %{"value" => "   "})
    html = render_hook(view, "confirm_rename", %{})

    refute html =~ "Rename failed"
    # Card header still shows the original name (it's a button now —
    # no `value="…"` to check for).
    assert html =~ "Headphones"
  end

  test "open_rename event with invalid key id is silently ignored", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    # Garbage id → handler can't find the card → no-op, no crash.
    html = render_hook(view, "open_rename", %{"id" => "not-a-real-key"})
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

    # Stream banner only surfaces the codec text when both `connected`
    # AND a stream snapshot are present. The real binary always emits
    # `connected` before `stream_start`, so we mirror that here.
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

  test "confirm_rename with all-control-chars draft is silently dropped",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    id = encode(@hp_key)

    # Open the modal, then push an all-control-chars draft. `clean_friendly_name/1`
    # strips controls and trims — the result is "" — so `confirm_rename`
    # treats this as a soft cancel: no `Audio.update_config` call, no
    # flash, modal just closes.
    _ = render_hook(view, "open_rename", %{"id" => id})
    _ = render_hook(view, "rename_draft", %{"value" => "\t\n\v\r"})
    html = render_hook(view, "confirm_rename", %{})

    refute html =~ "Rename failed"
    # Card header still shows the original name.
    assert html =~ "Headphones"
  end

  test "open_rename rejects correctly-encoded but wrong-shape keys", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/audio")

    # A valid base64 of a valid Erlang term that isn't a 3-tuple. Even
    # if a tampered DOM param survived `Base.url_decode64`, `open_rename`
    # only succeeds when the id is present in the cached outputs map —
    # which a wrong-shape key never can be. No crash, no modal opens.
    bad_id = :not_a_key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

    html = render_hook(view, "open_rename", %{"id" => bad_id})

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
