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

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub

  @hp_key {"bcm2835 Headphones", nil, nil}

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

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

  test "binary connection events flip the badge to Streaming", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    assert render(view) =~ "Stopped"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "connected"}}
    )

    assert render(view) =~ "Streaming"
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
