defmodule UniversalProxyWeb.OverviewBTD700Test do
  @moduledoc "Phase 6: Sennheiser BTD 700 control drawer on the Overview tab."
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import UniversalProxy.AudioFixtures

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub

  @key {"1-1.4", 0x3542, 0x3001}
  @fma120_key {"1-1.3", 0x0A12, 0x4007}

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp enc(key), do: key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  defp add_btd700_output(view) do
    out =
      sample_output(%{
        key: @key,
        card_index: 2,
        alsa_device: "plughw:2,0",
        usb_port: "1-1.4",
        card_name: "BTD 700",
        friendly_name: "Sennheiser BTD 700"
      })

    Phoenix.PubSub.broadcast(@pubsub, "sendspin:output_added", {:sendspin_output_added, out})
    render(view)
  end

  test "a BTD700 audio card routes its row to the control drawer, not the Audio tab",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    html = add_btd700_output(view)

    assert html =~ "select_btd700"
    assert html =~ enc(@key)
  end

  test "selecting the BTD700 opens the drawer with the unicast body in high-quality mode",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    send(
      view.pid,
      {:btd700_state, @key,
       %{
         firmware_version: %{major: 3, minor: 11, build: 0, version: "3.11.0"},
         audio_mode: %{mode: :high_quality, transport: :classic},
         dongle_state: :connected,
         supported_codecs: [:sbc, :aptx],
         codec_in_use: [:sbc]
       }}
    )

    html = render_click(view, "select_btd700", %{"key" => enc(@key)})

    assert html =~ "Firmware 3.11.0"
    assert html =~ "Connected"
    assert html =~ "Connect"
    assert html =~ "Disconnect"
    assert html =~ "SBC"
    refute html =~ "Broadcast name"
  end

  test "switching to broadcast mode swaps the drawer body", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    send(
      view.pid,
      {:btd700_state, @key, %{audio_mode: %{mode: :high_quality, transport: :classic}}}
    )

    render_click(view, "select_btd700", %{"key" => enc(@key)})

    send(
      view.pid,
      {:btd700_state, @key, %{audio_mode: %{mode: :broadcast, transport: :classic}}}
    )

    html = render(view)

    assert html =~ "Broadcast name"
    assert html =~ "Broadcast key"
    refute html =~ "Audio quality"
  end

  test "a btd700:state PubSub update patches the open drawer's status line", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    send(
      view.pid,
      {:btd700_state, @key,
       %{audio_mode: %{mode: :high_quality, transport: :classic}, dongle_state: :disconnected}}
    )

    html = render_click(view, "select_btd700", %{"key" => enc(@key)})
    assert html =~ "Not connected"

    send(view.pid, {:btd700_state, @key, %{dongle_state: :connected}})
    html = render(view)

    assert html =~ "Connected"
    refute html =~ "Not connected"
  end

  test "in broadcast mode the header shows broadcast status, not the unicast link state",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    send(
      view.pid,
      {:btd700_state, @key,
       %{
         audio_mode: %{mode: :broadcast, transport: :le_audio},
         dongle_state: :disconnected,
         broadcast_info: %{state: :on_public, encryption: :off, quality: :standard_16k},
         broadcast_name: "Kitchen"
       }}
    )

    html = render_click(view, "select_btd700", %{"key" => enc(@key)})
    assert html =~ "Broadcasting"
    assert html =~ "Kitchen"
    refute html =~ "Not connected"

    send(
      view.pid,
      {:btd700_state, @key,
       %{broadcast_info: %{state: :off_private, encryption: :off, quality: :standard_16k}}}
    )

    html = render(view)
    assert html =~ "Broadcast off"
    refute html =~ "Not connected"
  end

  # Dongle fw 3.11.0 rejects quality writes (raw-HID-verified) — the
  # buttons render disabled so the UI doesn't offer a dead affordance.
  test "broadcast quality buttons are disabled with an explanatory hint", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    send(
      view.pid,
      {:btd700_state, @key,
       %{
         audio_mode: %{mode: :broadcast, transport: :le_audio},
         broadcast_info: %{state: :on_public, encryption: :off, quality: :standard_16k}
       }}
    )

    html = render_click(view, "select_btd700", %{"key" => enc(@key)})

    assert html =~ "Fixed by the dongle firmware"

    quality_buttons =
      html
      |> String.split("<button")
      |> Enum.filter(&(&1 =~ "btd700_set_bcast_quality"))

    assert length(quality_buttons) == 3
    for btn <- quality_buttons, do: assert(btn =~ "disabled")
  end

  # Protocol hands broadcast names back as raw wire bytes. Invalid UTF-8
  # survives HTML escaping but crashes the connected render's JSON diff
  # (Jason raises) — the assign boundary must scrub it (verified in review,
  # 2026-07-19).
  test "an invalid-UTF-8 broadcast name from the wire cannot crash the connected render",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    send(
      view.pid,
      {:btd700_state, @key,
       %{
         audio_mode: %{mode: :broadcast, transport: :le_audio},
         broadcast_info: %{state: :on_public, encryption: :off, quality: :standard_16k},
         broadcast_name: <<0xFF, 0xFE, "garbage">>
       }}
    )

    html = render_click(view, "select_btd700", %{"key" => enc(@key)})
    assert html =~ "Auracast" or html =~ "Broadcast"
    assert Process.alive?(view.pid)
  end

  test "mode/codec/connect/factory-reset events are handled without crashing the view",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    send(
      view.pid,
      {:btd700_state, @key,
       %{
         audio_mode: %{mode: :high_quality, transport: :classic},
         supported_codecs: [:sbc, :aptx],
         codec_in_use: [:sbc]
       }}
    )

    render_click(view, "select_btd700", %{"key" => enc(@key)})

    # No worker is attached on host, so the boundary returns {:error, :not_found};
    # the LiveView must stay alive and keep rendering the drawer.
    html = render_click(view, "btd700_set_mode", %{"key" => enc(@key), "mode" => "gaming"})
    assert html =~ "Audio mode"
    assert Process.alive?(view.pid)

    html = render_click(view, "btd700_toggle_codec", %{"key" => enc(@key), "codec" => "aptx"})
    assert html =~ "Audio mode"
    assert Process.alive?(view.pid)

    html = render_click(view, "btd700_connect", %{"key" => enc(@key)})
    assert html =~ "Audio mode"
    assert Process.alive?(view.pid)

    html = render_click(view, "btd700_disconnect", %{"key" => enc(@key)})
    assert html =~ "Audio mode"
    assert Process.alive?(view.pid)

    html = render_click(view, "btd700_factory_reset", %{"key" => enc(@key)})
    assert html =~ "Audio mode"
    assert Process.alive?(view.pid)
  end

  test "broadcast state/quality/encryption/name events are handled without crashing the view",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    send(
      view.pid,
      {:btd700_state, @key,
       %{
         audio_mode: %{mode: :broadcast, transport: :classic},
         broadcast_info: %{state: :off_private, encryption: :off, quality: :standard_16k},
         broadcast_name: "My Auracast"
       }}
    )

    render_click(view, "select_btd700", %{"key" => enc(@key)})

    _html = render_click(view, "btd700_set_bcast_state", %{"key" => enc(@key)})
    assert Process.alive?(view.pid)

    _html =
      render_click(view, "btd700_set_bcast_quality", %{"key" => enc(@key), "quality" => "high"})

    assert Process.alive?(view.pid)

    _html = render_click(view, "btd700_set_bcast_enc", %{"key" => enc(@key)})
    assert Process.alive?(view.pid)

    html =
      view
      |> form("form[phx-submit='btd700_set_bcast_name']", %{
        "key" => enc(@key),
        "name" => "New Name"
      })
      |> render_submit()

    assert html =~ "Audio mode"
    assert Process.alive?(view.pid)
  end

  test "the broadcast key form never echoes the submitted passphrase into rendered HTML",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    send(
      view.pid,
      {:btd700_state, @key, %{audio_mode: %{mode: :broadcast, transport: :classic}}}
    )

    html = render_click(view, "select_btd700", %{"key" => enc(@key)})
    refute html =~ "supersecretpass"

    html =
      render_click(view, "btd700_set_bcast_key", %{
        "key" => enc(@key),
        "secret" => "supersecretpass"
      })

    refute html =~ "supersecretpass"
    assert Process.alive?(view.pid)
  end

  test "the factory-reset button is guarded by a data-confirm attribute", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    send(
      view.pid,
      {:btd700_state, @key, %{audio_mode: %{mode: :high_quality, transport: :classic}}}
    )

    html = render_click(view, "select_btd700", %{"key" => enc(@key)})

    assert html =~ "data-confirm"
    assert html =~ "Factory reset this BTD 700"
  end

  test "an invalid (non-BTD700) key is ignored — the drawer never opens", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    html = render_click(view, "select_btd700", %{"key" => enc(@fma120_key)})

    refute html =~ "Audio mode"
    refute html =~ "Factory reset"
  end

  test "the drawer closes on close_btd700_drawer", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    add_btd700_output(view)

    send(
      view.pid,
      {:btd700_state, @key, %{audio_mode: %{mode: :high_quality, transport: :classic}}}
    )

    render_click(view, "select_btd700", %{"key" => enc(@key)})

    html = render_click(view, "close_btd700_drawer", %{})
    refute html =~ "Audio mode"
  end
end
