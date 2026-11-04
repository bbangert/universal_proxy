defmodule UniversalProxyWeb.CecUiTest do
  @moduledoc """
  The HDMI-CEC receiver pill and auto-wake toggle on the Audio tab's
  output cards and the Overview's audio rows.

  CEC is off on host, so `Cec.list_adapters/0` is `[]` at mount; adapter
  records are fed in as the `{:cec_adapters, adapters}` broadcasts
  `Cec.Server` sends, and outputs as `"sendspin:output_added"`, the same
  contract the LiveViews consume on a device. One test runs the real CEC
  subtree on the fake transport to cover the mount-time seed.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import UniversalProxy.AudioFixtures

  alias UniversalProxy.Cec
  alias UniversalProxyWeb.Components.Audio, as: AudioComponents

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub

  @hdmi_key {"vc4-hdmi", nil, nil}
  @hdmi_card 1

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  defp hdmi_output(overrides \\ %{}) do
    sample_output(
      Map.merge(
        %{
          key: @hdmi_key,
          card_index: @hdmi_card,
          alsa_device: "plughw:1,0",
          card_name: "vc4-hdmi",
          friendly_name: "HDMI"
        },
        overrides
      )
    )
  end

  defp adapter(overrides) do
    Map.merge(
      %{
        dev: "/dev/cec0",
        index: 0,
        hdmi_device: "fef00700.hdmi",
        card_index: @hdmi_card,
        running?: true,
        phys_addr: "1.0.0.0",
        logical_address: 4,
        configured?: true,
        active_source?: false,
        receiver_presence: :present,
        receiver: %{power: :on, volume: nil, muted: nil, updated_at: nil},
        backoff: nil
      },
      overrides
    )
  end

  defp receiver(power), do: %{power: power, volume: nil, muted: nil, updated_at: nil}

  defp add_output(output) do
    Phoenix.PubSub.broadcast(@pubsub, "sendspin:output_added", {:sendspin_output_added, output})
  end

  defp put_adapters(adapters),
    do: Phoenix.PubSub.broadcast(@pubsub, Cec.topic(), {:cec_adapters, adapters})

  defp encode(key), do: key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  defp audio_with_hdmi(conn) do
    {:ok, view, _html} = live(conn, "/audio")
    add_output(hdmi_output())
    assert render(view) =~ "plughw:1,0"
    view
  end

  defp pill(view), do: view |> element("#cec-#{encode(@hdmi_key)}") |> render()

  describe "Audio tab" do
    test "no CEC adapter: the HDMI card shows nothing CEC-related", %{conn: conn} do
      view = audio_with_hdmi(conn)
      html = render(view)

      refute html =~ "cec-"
      refute html =~ "Auto-wake receiver"
      refute html =~ "Receiver"
    end

    test "an adapter paired with another card leaves this output alone", %{conn: conn} do
      view = audio_with_hdmi(conn)
      put_adapters([adapter(%{card_index: 7})])

      refute render(view) =~ "Auto-wake receiver"
      refute has_element?(view, "#cec-#{encode(@hdmi_key)}")
    end

    test "pill states follow the adapter record", %{conn: conn} do
      view = audio_with_hdmi(conn)

      cases = [
        {adapter(%{}), "Receiver on"},
        {adapter(%{receiver: receiver(:standby)}), "Receiver standby"},
        {adapter(%{receiver: receiver(:to_standby)}), "Receiver standby"},
        {adapter(%{receiver: receiver(:to_on)}), "Receiver waking"},
        {adapter(%{receiver_presence: :absent, receiver: receiver(:unknown)}), "TV"},
        {adapter(%{receiver_presence: :absent, receiver: receiver(:on)}), "TV on"},
        {adapter(%{configured?: false, receiver: receiver(:unknown)}), "CEC unavailable"},
        {adapter(%{running?: false, configured?: false}), "CEC unavailable"}
      ]

      for {record, label} <- cases do
        put_adapters([record])
        assert pill(view) =~ label
      end
    end

    test "a crashing adapter shows its backoff", %{conn: conn} do
      view = audio_with_hdmi(conn)

      put_adapters([
        adapter(%{
          running?: false,
          configured?: false,
          backoff: %{crashes: 3, retry_in_ms: 4_000, reason: {:port_exit, 1}}
        })
      ])

      html = pill(view)
      assert html =~ "CEC retrying"
      assert html =~ "crashed 3 times; retrying in 4 s"
    end

    test "the pill updates live on a cec:events broadcast", %{conn: conn} do
      view = audio_with_hdmi(conn)

      put_adapters([adapter(%{receiver: receiver(:standby)})])
      assert pill(view) =~ "Receiver standby"

      put_adapters([adapter(%{receiver: receiver(:on)})])
      assert pill(view) =~ "Receiver on"

      # The adapter going away removes the pill and the toggle.
      put_adapters([])
      refute has_element?(view, "#cec-#{encode(@hdmi_key)}")
      refute render(view) =~ "Auto-wake receiver"
    end

    test "the auto-wake toggle shows the output's setting", %{conn: conn} do
      view = audio_with_hdmi(conn)
      put_adapters([adapter(%{})])
      toggle = "#cec-auto-wake-#{encode(@hdmi_key)}"

      # Unset: the env default (true).
      assert view |> element(toggle) |> render() =~ ~s(aria-checked="true")

      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:state",
        {:sendspin_state, @hdmi_key, %{cec_auto_wake: false}}
      )

      assert view |> element(toggle) |> render() =~ ~s(aria-checked="false")
    end

    test "clicking the toggle writes the flipped setting", %{conn: conn} do
      view = audio_with_hdmi(conn)
      put_adapters([adapter(%{})])

      # Audio.Server has no outputs on host (NullEnumerate), so the write is
      # refused as not_found; persistence is covered by the Audio.Server
      # tests. The handler must survive it.
      log =
        capture_log(fn ->
          view |> element("#cec-auto-wake-#{encode(@hdmi_key)}") |> render_click()
        end)

      assert log =~ "CEC auto-wake toggle failed"
      assert log =~ ":not_found"
      assert render(view) =~ "Auto-wake receiver"
    end
  end

  describe "Overview" do
    test "an HDMI row shows the pill only when its card is paired", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      add_output(hdmi_output())
      assert render(view) =~ "plughw:1,0"
      refute render(view) =~ "Receiver"

      put_adapters([adapter(%{receiver: receiver(:standby)})])
      assert render(view) =~ "Receiver standby"

      put_adapters([adapter(%{receiver_presence: :absent, receiver: receiver(:unknown)})])
      html = render(view)
      assert html =~ "the TV is controlled instead"
      refute html =~ "Receiver standby"
    end
  end

  describe "with the CEC subtree running" do
    import UniversalProxy.CecBus

    alias Circuits.CEC.Message
    alias Circuits.CEC.Transport.Fake

    setup do
      fake = start_supervised!({Fake, []})

      start_supervised!(
        {Cec.Supervisor,
         enabled: true,
         transport: Fake,
         transport_opts: [fake: fake],
         enumerate: fn ->
           %{
             "/dev/cec0" => %{
               dev: "/dev/cec0",
               index: 0,
               hdmi_device: "fef00700.hdmi",
               card_index: @hdmi_card
             }
           }
         end,
         output_lookup: fn _ -> :error end,
         scan_interval_ms: 60_000}
      )

      {:ok, fake: fake}
    end

    test "mount seeds the pill from Cec.list_adapters/0", %{conn: conn, fake: fake} do
      wait_until(fn -> match?({:ok, %{ready?: true, claim: :claimed}}, Cec.info("/dev/cec0")) end)
      state_change(fake, 0x1000, 0x10)
      {seq, %Message{to: 5, body: :poll}} = nth_tx(fake, 1)
      nack(fake, seq)

      wait_until(fn ->
        match?([%{configured?: true, receiver_presence: :absent}], Cec.list_adapters())
      end)

      {:ok, view, _html} = live(conn, "/audio")
      add_output(hdmi_output())
      assert pill(view) =~ "TV"
      assert render(view) =~ "Auto-wake receiver"
    end
  end

  describe "cec_status/1" do
    test "maps every record shape to a label and badge variant" do
      assert %{label: "Receiver on", variant: :success} = AudioComponents.cec_status(adapter(%{}))

      assert %{label: "TV standby", variant: :neutral} =
               AudioComponents.cec_status(
                 adapter(%{receiver_presence: :absent, receiver: receiver(:standby)})
               )

      assert %{label: "Receiver", variant: :neutral} =
               AudioComponents.cec_status(
                 adapter(%{receiver_presence: :unknown, receiver: receiver(:unknown)})
               )

      assert %{label: "CEC retrying", variant: :warning, title: title} =
               AudioComponents.cec_status(
                 adapter(%{
                   running?: false,
                   backoff: %{crashes: 1, retry_in_ms: 300_000, reason: :x}
                 })
               )

      assert title =~ "crashed 1 time; retrying in 5 min"
    end

    test "cec_by_card/1 drops adapters without a card" do
      assert %{1 => %{label: "Receiver on"}} =
               AudioComponents.cec_by_card([adapter(%{}), adapter(%{card_index: nil})])
    end
  end
end
