defmodule UniversalProxy.Cec.KeysTest do
  use ExUnit.Case, async: true

  alias Circuits.CEC.Message
  alias UniversalProxy.Cec.Keys

  defp body(bytes) do
    {:ok, %Message{body: body}} = Message.decode(<<0x04>> <> bytes)
    body
  end

  test "remote keys map from the CEC UI command codes" do
    for {code, key} <- [
          {0x00, :select},
          {0x2B, :select},
          {0x01, :up},
          {0x02, :down},
          {0x03, :left},
          {0x04, :right},
          {0x0D, :exit},
          {0x09, :menu},
          {0x44, :play},
          {0x60, :play},
          {0x46, :pause},
          {0x61, :play_pause},
          {0x45, :stop},
          {0x64, :stop},
          {0x4B, :forward},
          {0x4C, :backward},
          {0x49, :fast_forward},
          {0x48, :rewind},
          {0x71, :blue},
          {0x72, :red},
          {0x73, :green},
          {0x74, :yellow}
        ] do
      assert Keys.classify(body(<<0x44, code>>)) == {:press, key}, "UI command #{code}"
    end
  end

  test "Play Function's Play Mode operand maps like <Play>, as a press" do
    assert Keys.classify(body(<<0x44, 0x60>>)) == {:press, :play}
    assert Keys.classify(body(<<0x44, 0x60, 0x24>>)) == {:press, :play}
    assert Keys.classify(body(<<0x44, 0x60, 0x25>>)) == {:press, :pause}
    assert Keys.classify(body(<<0x44, 0x60, 0x05>>)) == {:press, :fast_forward}
    assert Keys.classify(body(<<0x44, 0x60, 0x0B>>)) == {:press, :rewind}
    assert Keys.classify(body(<<0x44, 0x60, 0x20>>)) == :ignore
    assert Keys.classify(body(<<0x44, 0x60, 0xEE>>)) == :ignore
  end

  test "other keys ignore extra operands" do
    assert Keys.classify(body(<<0x44, 0x01, 0x00>>)) == {:press, :up}
  end

  test "<Play> and <Deck Control> are one-shot commands" do
    assert Keys.classify(body(<<0x41, 0x24>>)) == {:command, :play}
    assert Keys.classify(body(<<0x41, 0x25>>)) == {:command, :pause}
    assert Keys.classify(body(<<0x41, 0x06>>)) == {:command, :fast_forward}
    assert Keys.classify(body(<<0x41, 0x0B>>)) == {:command, :rewind}
    assert Keys.classify(body(<<0x42, 0x01>>)) == {:command, :forward}
    assert Keys.classify(body(<<0x42, 0x02>>)) == {:command, :backward}
    assert Keys.classify(body(<<0x42, 0x03>>)) == {:command, :stop}
    assert Keys.classify(body(<<0x42, 0x04>>)) == :ignore
    assert Keys.classify(body(<<0x41, 0x20>>)) == :ignore
  end

  test "releases, unmapped keys and other messages" do
    assert Keys.classify(:user_control_released) == :release
    assert Keys.classify(body(<<0x44, 0x21>>)) == :ignore
    assert Keys.classify(body(<<0x44, 0x41>>)) == :ignore
    assert Keys.classify(body(<<0x44, 0xFE>>)) == :ignore
    assert Keys.classify(:standby) == :ignore
  end

  describe "step/3" do
    test "a press fires; a repeat of the held key within 550 ms doesn't" do
      assert {:up, held} = Keys.step(nil, {:press, :up}, 0)
      assert {nil, held} = Keys.step(held, {:press, :up}, 400)
      # The window slides with each repeat.
      assert {nil, held} = Keys.step(held, {:press, :up}, 900)
      assert {:up, _held} = Keys.step(held, {:press, :up}, 1_500)
    end

    test "a release ends the hold, so the next press fires" do
      {:up, held} = Keys.step(nil, {:press, :up}, 0)
      assert {nil, nil} = Keys.step(held, :release, 100)
      assert {:up, _} = Keys.step(nil, {:press, :up}, 150)
    end

    test "another key fires at once" do
      {:up, held} = Keys.step(nil, {:press, :up}, 0)
      assert {:down, {:down, 10}} = Keys.step(held, {:press, :down}, 10)
    end

    test "commands always fire and leave the hold alone" do
      {:up, held} = Keys.step(nil, {:press, :up}, 0)
      assert {:play, ^held} = Keys.step(held, {:command, :play}, 10)
      assert {:play, ^held} = Keys.step(held, {:command, :play}, 20)
      assert {nil, ^held} = Keys.step(held, :ignore, 30)
    end
  end
end
