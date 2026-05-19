defmodule UniversalProxyWeb.OverviewLiveTest do
  @moduledoc """
  Focused tests for the audio-outputs summary row that was layered onto
  the Overview tab in Phase 4. The full-page smoke check stays in
  [render_smoke_test.exs](render_smoke_test.exs); this file drives the
  audio PubSub plumbing.
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

  test "Overview omits the audio card when no outputs are present", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    # Audio summary card is gated on a non-empty list, and the
    # test-env NullEnumerate keeps the Audio.Server list empty.
    refute html =~ "Audio outputs"
  end

  test "Overview renders an audio row when :sendspin_output_added arrives", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    html = render(view)
    assert html =~ "Audio outputs"
    assert html =~ "Headphones"
    assert html =~ "plughw:0,0"
    # Default badge for enabled-but-not-yet-streaming output.
    assert html =~ "Stopped"
  end

  test "binary events progress the badge through Stopped → Connected → Streaming",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    assert render(view) =~ "Stopped"

    # WebSocket up but no audio yet → "Connected", not "Streaming".
    # The Sendspin client holds the socket open between songs, so this
    # is the long-lived idle-but-attached state.
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "connected"}}
    )

    html = render(view)
    assert html =~ "Connected"
    refute html =~ ">Streaming<"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key,
       %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
    )

    assert render(view) =~ "Streaming"
  end

  test "stream_end while still connected drops the badge back to Connected", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

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

    # The exact bug PR #41 fixes — track ends, server keeps the
    # WebSocket open, badge must NOT stay on "Streaming".
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "stream_end"}}
    )

    html = render(view)
    assert html =~ "Connected"
    refute html =~ ">Streaming<"
  end

  test "disconnected clears the stream snapshot so badge can't read Streaming",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    # Race scenario: server pushed `stream_start`, then the socket
    # dropped before `stream_end`. The disconnected handler must clear
    # the cached stream — otherwise the badge would read "Streaming"
    # right up until the next `stream_end`, which never arrives.
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
      {:sendspin_state, @hp_key, %{event: "disconnected"}}
    )

    html = render(view)
    assert html =~ "Searching"
    refute html =~ ">Streaming<"
  end

  test "Manage link points at /audio", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    assert render(view) =~ ~s|href="/audio"|
  end
end
