defmodule UniversalProxy.Cec.VolumeTest do
  # async: false - the subtree runs under its fixed registered names.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import UniversalProxy.CecBus

  alias Circuits.CEC.Message
  alias Circuits.CEC.Transport.Fake
  alias UniversalProxy.Cec

  @dev "/dev/cec0"
  @key {"vc4-hdmi", nil, nil}
  @adapter_info %{dev: @dev, index: 0, hdmi_device: "fef00700.hdmi", card_index: 1}

  # Transmit 1 is configure/2's receiver poll.
  @first_tx 2

  setup context do
    fake = start_supervised!({Fake, []})
    test = self()

    # A volume link over the real adapter, for one HDMI output on card 1.
    volume_link =
      if context[:volume_link] do
        [
          list_outputs: fn -> [%{key: @key, card_index: 1, volume: 50, muted: false}] end,
          set_volume_external: fn key, external? -> send(test, {:external, key, external?}) end,
          update_config: fn key, params ->
            send(test, {:update_config, key, params})
            {:ok, nil}
          end,
          poll_ms: 50,
          probe_ms: 50,
          hotplug_grace_ms: 0
        ]
      else
        []
      end

    start_supervised!(
      {Cec.Supervisor,
       enabled: true,
       transport: Fake,
       transport_opts: [fake: fake],
       enumerate: fn -> %{@dev => @adapter_info} end,
       output_lookup: fn _ -> :error end,
       receiver_la: 5,
       scan_interval_ms: 60_000,
       tv_presence: false,
       volume_link: volume_link}
    )

    configure(fake, :present)
    {:ok, fake: fake}
  end

  describe "set_volume/3" do
    test "steps up, reading back after every press", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 22) end)

      n = status(fake, @first_tx, 20)
      n = press(fake, n, :volume_up, 21)
      n = press(fake, n, :volume_up, 22)

      assert Task.await(task) == {:ok, %{volume: 22, muted: false, step: 1}}
      refute_tx(fake, n)
    end

    test "steps down", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 18) end)

      n = status(fake, @first_tx, 20)
      n = press(fake, n, :volume_down, 19)
      n = press(fake, n, :volume_down, 18)

      assert Task.await(task) == {:ok, %{volume: 18, muted: false, step: 1}}
      refute_tx(fake, n)
    end

    test "already at the target presses nothing", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 20) end)
      n = status(fake, @first_tx, 20)

      assert Task.await(task) == {:ok, %{volume: 20, muted: false, step: 1}}
      refute_tx(fake, n)
    end

    test "a single dropped press is tolerated", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 21) end)

      n = status(fake, @first_tx, 20)
      n = press(fake, n, :volume_up, 20)
      _ = press(fake, n, :volume_up, 21)

      assert Task.await(task) == {:ok, %{volume: 21, muted: false, step: 1}}
    end

    test "stops after two presses in a row make no progress", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 30) end)

      n = status(fake, @first_tx, 20)
      n = press(fake, n, :volume_up, 21)
      n = press(fake, n, :volume_up, 21)
      n = press(fake, n, :volume_up, 21)

      assert Task.await(task) == {:error, {:no_progress, %{volume: 21, muted: false, step: 1}}}
      refute_tx(fake, n)
    end

    test "a coarse step that passes the target stops when going back is no closer",
         %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 21) end)

      n = status(fake, @first_tx, 20)
      n = press(fake, n, :volume_up, 22)

      assert Task.await(task) == {:ok, %{volume: 22, muted: false, step: 2}}
      refute_tx(fake, n)
    end

    test "presses are bounded", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 30, max_presses: 2) end)

      n = status(fake, @first_tx, 20)
      n = press(fake, n, :volume_up, 21)
      n = press(fake, n, :volume_up, 22)

      assert Task.await(task) == {:error, {:press_limit, %{volume: 22, muted: false, step: 1}}}
      refute_tx(fake, n)
    end

    test "a receiver that won't report its volume is unknown_volume", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 30) end)
      {seq, %Message{to: 5, body: :give_audio_status}} = nth_tx(fake, @first_tx)
      reply(fake, seq, <<0x54, 0x7A, 0x7F>>)

      assert Task.await(task) == {:error, :unknown_volume}
    end

    test "a first readback that fails is a bare error", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 30) end)
      {seq, %Message{to: 5, body: :give_audio_status}} = nth_tx(fake, @first_tx)
      complete(fake, seq, tx_status: 0x01, rx_status: 0x04)

      assert Task.await(task) == {:error, :feature_abort}
    end

    test "a failed readback mid-walk is returned", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 30) end)

      n = status(fake, @first_tx, 20)
      {seq, _} = nth_tx(fake, n)
      ack(fake, seq)
      {seq, _} = nth_tx(fake, n + 1)
      ack(fake, seq)
      {seq, %Message{body: :give_audio_status}} = nth_tx(fake, n + 2)
      complete(fake, seq, tx_status: 0x01, rx_status: 0x04)

      assert Task.await(task) ==
               {:error, {:feature_abort, %{volume: 20, muted: false, step: 1}}}
    end

    test "a failure after some progress returns where the walk got to", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 30) end)

      n = status(fake, @first_tx, 20)
      n = press(fake, n, :volume_up, 21)
      {seq, %Message{body: {:user_control_pressed, :volume_up}}} = nth_tx(fake, n)
      ack(fake, seq)
      {seq, _} = nth_tx(fake, n + 1)
      ack(fake, seq)
      {seq, %Message{body: :give_audio_status}} = nth_tx(fake, n + 2)
      complete(fake, seq, tx_status: 0x01, rx_status: 0x04)

      assert Task.await(task) ==
               {:error, {:feature_abort, %{volume: 21, muted: false, step: 1}}}
    end

    test "a readback without a volume mid-walk is unknown_volume with the last result",
         %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 30) end)

      n = status(fake, @first_tx, 20)
      {seq, _} = nth_tx(fake, n)
      ack(fake, seq)
      {seq, _} = nth_tx(fake, n + 1)
      ack(fake, seq)
      {seq, %Message{body: :give_audio_status}} = nth_tx(fake, n + 2)
      reply(fake, seq, <<0x54, 0x7A, 0x7F>>)

      assert Task.await(task) ==
               {:error, {:unknown_volume, %{volume: 20, muted: false, step: 1}}}
    end
  end

  describe "set_volume/3 with a step-3 receiver" do
    test "a known step that can't get closer presses nothing", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 25, step: 3) end)
      n = status(fake, @first_tx, 24)

      assert Task.await(task) == {:ok, %{volume: 24, muted: false, step: 3}}
      refute_tx(fake, n)
    end

    test "settles on the nearest reachable value past the target", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 26) end)

      n = status(fake, @first_tx, 24)
      n = press(fake, n, :volume_up, 27)

      assert Task.await(task) == {:ok, %{volume: 27, muted: false, step: 3}}
      refute_tx(fake, n)
    end

    test "the step is learned from the first press and plans the rest", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 29) end)

      n = status(fake, @first_tx, 21)
      n = press(fake, n, :volume_up, 24)
      n = press(fake, n, :volume_up, 27)
      n = press(fake, n, :volume_up, 30)

      assert Task.await(task) == {:ok, %{volume: 30, muted: false, step: 3}}
      refute_tx(fake, n)
    end

    test "an unknown step that overshoots comes back to the nearer side", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 25) end)

      n = status(fake, @first_tx, 24)
      n = press(fake, n, :volume_up, 27)
      n = press(fake, n, :volume_down, 24)

      assert Task.await(task) == {:ok, %{volume: 24, muted: false, step: 3}}
      refute_tx(fake, n)
    end

    test "a step from an earlier run is kept when nothing is pressed", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 24, step: 3) end)
      n = status(fake, @first_tx, 24)

      assert Task.await(task) == {:ok, %{volume: 24, muted: false, step: 3}}
      refute_tx(fake, n)
    end

    test "a press that lands on a rail doesn't teach the step", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 100, step: 3) end)

      n = status(fake, @first_tx, 98)
      n = press(fake, n, :volume_up, 100)

      assert Task.await(task) == {:ok, %{volume: 100, muted: false, step: 3}}
      refute_tx(fake, n)
    end
  end

  describe "set_volume/3 with :max" do
    test "never presses up past the ceiling", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 30, max: 25, step: 3) end)
      n = status(fake, @first_tx, 24)

      assert Task.await(task) == {:ok, %{volume: 24, muted: false, step: 3}}
      refute_tx(fake, n)
    end

    test "an unknown step that overshoots the ceiling steps back under it", %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 30, max: 25) end)

      n = status(fake, @first_tx, 24)
      n = press(fake, n, :volume_up, 27)
      n = press(fake, n, :volume_down, 24)

      assert Task.await(task) == {:ok, %{volume: 24, muted: false, step: 3}}
      refute_tx(fake, n)
    end

    test "starting above the ceiling steps down even past the nearest value",
         %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 25, max: 25, step: 3) end)

      n = status(fake, @first_tx, 26)
      n = press(fake, n, :volume_down, 23)

      assert Task.await(task) == {:ok, %{volume: 23, muted: false, step: 3}}
      refute_tx(fake, n)
    end

    test "starting above the ceiling with a target below it walks to the target",
         %{fake: fake} do
      task = Task.async(fn -> Cec.set_volume(@dev, 20, max: 25) end)

      n = status(fake, @first_tx, 30)
      n = press(fake, n, :volume_down, 27)
      n = press(fake, n, :volume_down, 24)
      n = press(fake, n, :volume_down, 21)

      assert Task.await(task) == {:ok, %{volume: 21, muted: false, step: 3}}
      refute_tx(fake, n)
    end

    test "rejects a bad :max or :step" do
      assert_raise ArgumentError, fn -> Cec.set_volume(@dev, 20, max: 101) end
      assert_raise ArgumentError, fn -> Cec.set_volume(@dev, 20, step: 0) end
    end
  end

  describe "set_muted/3" do
    test "already in the wanted state presses nothing", %{fake: fake} do
      task = Task.async(fn -> Cec.set_muted(@dev, true) end)
      n = status(fake, @first_tx, 20, true)

      assert Task.await(task) == {:ok, %{volume: 20, muted: true}}
      refute_tx(fake, n)
    end

    test "toggles once and returns the readback", %{fake: fake} do
      task = Task.async(fn -> Cec.set_muted(@dev, true) end)

      n = status(fake, @first_tx, 20)
      n = press(fake, n, :mute, 20, true)

      assert Task.await(task) == {:ok, %{volume: 20, muted: true}}
      refute_tx(fake, n)
    end

    test "retries a dropped press once, then reports what it got", %{fake: fake} do
      task = Task.async(fn -> Cec.set_muted(@dev, false) end)

      n = status(fake, @first_tx, 20, true)
      n = press(fake, n, :mute, 20, true)
      n = press(fake, n, :mute, 20, true)

      assert Task.await(task) == {:ok, %{volume: 20, muted: true}}
      refute_tx(fake, n)
    end
  end

  describe "explicit destinations" do
    test "a NACK at an explicit address isn't retried at the TV", %{fake: fake} do
      task = Task.async(fn -> Cec.audio_status(@dev, to: 5) end)
      {seq, %Message{to: 5, body: :give_audio_status}} = nth_tx(fake, @first_tx)
      nack(fake, seq)
      assert Task.await(task) == {:error, :nack}

      task = Task.async(fn -> Cec.set_volume(@dev, 30, to: 5) end)
      n = status(fake, @first_tx + 1, 20)
      {seq, %Message{to: 5, body: {:user_control_pressed, :volume_up}}} = nth_tx(fake, n)
      nack(fake, seq)

      assert Task.await(task) == {:error, {:nack, %{volume: 20, muted: false, step: 1}}}
      refute_tx(fake, n + 1)
      assert {:ok, %{receiver_presence: :present}} = Cec.Server.get_adapter(@dev)
    end

    test "an explicit address is used while the adapter holds the receiver absent",
         %{fake: fake} do
      # A `:receiver` press the receiver NACKs: retried at the TV, and from
      # then on the adapter sends `:receiver` commands there.
      task = Task.async(fn -> Cec.volume_up(@dev) end)
      {seq, %Message{to: 5}} = nth_tx(fake, @first_tx)
      nack(fake, seq)
      {seq, %Message{to: 0}} = nth_tx(fake, @first_tx + 1)
      ack(fake, seq)
      {seq, %Message{to: 0, body: :user_control_released}} = nth_tx(fake, @first_tx + 2)
      ack(fake, seq)
      assert Task.await(task) == :ok

      wait_until(fn ->
        match?({:ok, %{receiver_presence: :absent}}, Cec.Server.get_adapter(@dev))
      end)

      task = Task.async(fn -> Cec.set_volume(@dev, 21, to: 5) end)
      n = status(fake, @first_tx + 3, 20)
      n = press(fake, n, :volume_up, 21)
      assert Task.await(task) == {:ok, %{volume: 21, muted: false, step: 1}}
      refute_tx(fake, n)
    end
  end

  describe "a volume link on the bus" do
    @tag volume_link: true
    test "links at the receiver's address and never asks the TV", %{fake: fake} do
      # Probed at the receiver's address once it is present.
      {seq, %Message{to: 5, body: :give_device_power_status}} = nth_tx(fake, @first_tx)
      reply(fake, seq, <<0x54, 0x90, 0x00>>)
      n = status(fake, @first_tx + 1, 20)
      assert_receive {:external, @key, true}, 1_000

      # Every poll the receiver NACKs counts (each asks for the power status
      # and the audio status); none goes to the TV.
      for i <- 0..5 do
        {seq, %Message{to: 5}} = nth_tx(fake, n + i)
        nack(fake, seq)
      end

      assert_receive {:external, @key, false}, 1_000
      assert Enum.all?(transmits(fake), fn {_seq, %Message{to: to}} -> to == 5 end)
    end
  end

  test "with the subsystem off both degrade" do
    stop_supervised!(Cec.Supervisor)
    assert Cec.set_volume(@dev, 30) == {:error, :cec_unavailable}
    assert Cec.set_muted(@dev, true) == {:error, :cec_unavailable}
  end

  # Answers the <Give Audio Status> at transmit `n`; returns the next index.
  defp status(fake, n, volume, muted \\ false) do
    {seq, %Message{to: 5, body: :give_audio_status}} = nth_tx(fake, n)
    mute_bit = if muted, do: 0x80, else: 0x00
    reply(fake, seq, <<0x54, 0x7A, Bitwise.bor(mute_bit, volume)>>)
    n + 1
  end

  # Acks the key press and release at `n`, then answers the readback.
  defp press(fake, n, key, volume, muted \\ false) do
    {seq, %Message{to: 5, body: {:user_control_pressed, ^key}}} = nth_tx(fake, n)
    ack(fake, seq)
    {seq, %Message{to: 5, body: :user_control_released}} = nth_tx(fake, n + 1)
    ack(fake, seq)
    status(fake, n + 2, volume, muted)
  end

  # The call has returned, so nothing more can go out.
  defp refute_tx(fake, n), do: assert(length(transmits(fake)) == n - 1)
end
