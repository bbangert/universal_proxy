defmodule UniversalProxyWeb.OverviewFMA120Test do
  @moduledoc "Phase 8: FMA120 control drawer on the Overview tab."
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import UniversalProxy.AudioFixtures

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub

  @key {"1-1.3", 0x0A12, 0x4007}

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp enc(key), do: key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  defp add_fma120_output(view) do
    out =
      sample_output(%{
        key: @key,
        card_index: 1,
        alsa_device: "plughw:1,0",
        usb_port: "1-1.3",
        card_name: "FlooGoo FMA120",
        friendly_name: "FlooGoo FMA120"
      })

    Phoenix.PubSub.broadcast(@pubsub, "sendspin:output_added", {:sendspin_output_added, out})
    render(view)
  end

  test "an FMA120 audio card routes its row to the control drawer, not the Audio tab",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = add_fma120_output(view)

    assert html =~ "select_fma120"
    assert html =~ enc(@key)
  end

  test "selecting the FMA120 opens the drawer with the unicast body in high-quality mode",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_fma120_output(view)

    send(
      view.pid,
      {:fma120_state, @key,
       %{version: "1.1.7G", audio_mode: %{quality: :high_quality, variant: :fma120}}}
    )

    html = render_click(view, "select_fma120", %{"key" => enc(@key)})

    assert html =~ "Firmware 1.1.7G"
    assert html =~ "High Quality"
    # Unicast body markers.
    assert html =~ "Profile preference"
    assert html =~ "Scan"
    refute html =~ "Broadcast name"
  end

  test "switching to broadcast mode swaps the drawer body", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_fma120_output(view)

    send(
      view.pid,
      {:fma120_state, @key, %{audio_mode: %{quality: :high_quality, variant: :fma120}}}
    )

    render_click(view, "select_fma120", %{"key" => enc(@key)})

    # A mode-change broadcast re-renders the body as the Auracast variant.
    send(view.pid, {:fma120_state, @key, %{audio_mode: %{quality: :broadcast, variant: :fma120}}})
    html = render(view)

    assert html =~ "Broadcast name"
    refute html =~ "Profile preference"
  end

  test "a control event in the drawer is handled without crashing the view", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_fma120_output(view)

    send(
      view.pid,
      {:fma120_state, @key, %{audio_mode: %{quality: :high_quality, variant: :fma120}}}
    )

    render_click(view, "select_fma120", %{"key" => enc(@key)})

    # No worker is attached on host, so the context returns {:error, :not_found};
    # the LiveView must stay alive and keep rendering the drawer.
    html = render_click(view, "fma120_set_mode", %{"key" => enc(@key), "mode" => "gaming"})
    assert html =~ "Audio mode"
    assert Process.alive?(view.pid)
  end

  test "a malformed device index is ignored (no-op), not coerced to 0", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_fma120_output(view)

    send(
      view.pid,
      {:fma120_state, @key, %{audio_mode: %{quality: :high_quality, variant: :fma120}}}
    )

    render_click(view, "select_fma120", %{"key" => enc(@key)})

    # A tampered/garbage index must not crash and must not act on device 0.
    html = render_click(view, "fma120_connect", %{"key" => enc(@key), "index" => "garbage"})
    assert html =~ "Audio mode"
    assert Process.alive?(view.pid)

    html = render_click(view, "fma120_forget", %{"key" => enc(@key), "index" => "99x"})
    assert html =~ "Audio mode"
    assert Process.alive?(view.pid)
  end

  test "the drawer closes on close_fma120_drawer", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_fma120_output(view)

    send(
      view.pid,
      {:fma120_state, @key, %{audio_mode: %{quality: :high_quality, variant: :fma120}}}
    )

    render_click(view, "select_fma120", %{"key" => enc(@key)})

    html = render_click(view, "close_fma120_drawer", %{})
    refute html =~ "Audio mode"
  end
end
