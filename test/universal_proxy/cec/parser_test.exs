defmodule UniversalProxy.Cec.ParserTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Cec.Parser

  @monitor """
  Received from Audio System to Playback Device 1 (5 to 4): REPORT_POWER_STATUS (0x90):
  \tpwr-state: On (0x00)
  Transmitted by Playback Device 1 to TV (4 to 0): IMAGE_VIEW_ON (0x04)
  Received from TV to all (0 to 15): STANDBY (0x36)
  12:00:01.234: Event: State Change: PA: f.f.f.f, LA mask: 0x0000
  Initial Event: State Change: PA: 1.0.0.0, LA mask: 0x0010, Conn Info: card 1, connector 32
  Event: Lost 2 messages
  Received from Audio System to all (5 to 15): SET_SYSTEM_AUDIO_MODE (0x72):
  \tsys-aud-status: On (0x01)
  \tSequence: 9 Rx Timestamp: 12:00:02.000
  Received from Audio System to Playback Device 1 (5 to 4): REPORT_AUDIO_STATUS (0x7a):
  \taud-mute-status: On (0x01)
  \taud-vol-status: 55 (0x37)
  """

  test "parses monitor messages, arguments and events in order" do
    records = Parser.parse(@monitor)

    assert [
             %{
               type: :message,
               direction: :received,
               from: 5,
               to: 4,
               opcode: "REPORT_POWER_STATUS",
               code: 0x90
             } = power,
             %{
               type: :message,
               direction: :transmitted,
               from: 4,
               to: 0,
               opcode: "IMAGE_VIEW_ON",
               args: %{}
             },
             %{type: :message, direction: :received, from: 0, to: :all, opcode: "STANDBY"},
             %{type: :event, kind: :state_change, phys_addr: "f.f.f.f", la_mask: 0},
             %{type: :event, kind: :state_change, phys_addr: "1.0.0.0", la_mask: 0x10},
             %{type: :event, kind: :other, text: "Lost 2 messages"},
             %{
               type: :message,
               opcode: "SET_SYSTEM_AUDIO_MODE",
               args: %{"sys-aud-status" => %{text: "On", value: 1}}
             },
             %{type: :message, opcode: "REPORT_AUDIO_STATUS"} = audio
           ] = records

    assert power.args == %{"pwr-state" => %{text: "On", value: 0}}
    assert Parser.power_state(power) == :on
    assert Parser.audio_status(audio) == %{volume: 55, muted: true}
  end

  test "streaming feed completes a record only when the next header or a blank line arrives" do
    st = Parser.new()

    {st, []} =
      Parser.feed(
        st,
        "Received from Audio System to Playback Device 1 (5 to 4): REPORT_POWER_STATUS (0x90):"
      )

    {st, []} = Parser.feed(st, "\tpwr-state: Standby (0x01)")
    {st, [rec]} = Parser.feed(st, "")
    assert Parser.power_state(rec) == :standby
    {_st, []} = Parser.finish(st)
  end

  test "decodes a one-shot reply with its indented opcode line" do
    out = """

    Transmit from Playback Device 1 to Audio System (4 to 5):
    GIVE_DEVICE_POWER_STATUS (0x8f)
        Received from Audio System (5):
        REPORT_POWER_STATUS (0x90):
    \tpwr-state: In transition On to Standby (0x03)
    \tSequence: 3 Tx Timestamp: 10:00:00.000 Rx Timestamp: 10:00:00.120
    """

    assert %{direction: :received, from: 5, opcode: "REPORT_POWER_STATUS"} =
             reply = Parser.reply(out)

    assert Parser.power_state(reply) == :to_standby
  end

  test "a one-shot with no reply (timeout / feature abort) yields nil" do
    out = """

    Transmit from Playback Device 1 to TV (4 to 0):
    IMAGE_VIEW_ON (0x04)
    \tSequence: 1 Tx Timestamp: 10:00:00.000
    """

    assert Parser.reply(out) == nil
  end

  test "reads the adapter's physical and logical address from Driver Info" do
    info = """
    Driver Info:
    \tDriver Name                : vc4_hdmi
    \tPhysical Address           : 2.1.0.0
    \tLogical Address Mask       : 0x0100

    \t  Logical Address          : 8 (Playback Device 2)
    \t    Primary Device Type    : Playback
    """

    assert Parser.driver_info(info) == %{phys_addr: "2.1.0.0", logical_address: 8}
    assert Parser.driver_info("garbage") == %{phys_addr: nil, logical_address: nil}
  end

  test "unknown volume (0x7f) and invalid physical addresses are recognised" do
    rec = %{
      args: %{
        "aud-vol-status" => %{text: "127", value: 0x7F},
        "aud-mute-status" => %{text: "Off", value: 0}
      }
    }

    assert Parser.audio_status(rec) == %{volume: nil, muted: false}
    refute Parser.valid_phys_addr?("f.f.f.f")
    refute Parser.valid_phys_addr?(nil)
    assert Parser.valid_phys_addr?("1.0.0.0")
  end

  test "timestamped events from `cec-ctl -m` (monotonic and --wall-clock) are recognised" do
    out = """

    Initial Event: State Change: PA: 1.0.0.0, LA mask: 0x0010

    1234.567890: Event: State Change: PA: f.f.f.f, LA mask: 0x0000

    1234.600000s: Event: Lost 3 messages

    Wed Oct 28 12:34:56.123456: Event: State Change: PA: 2.0.0.0, LA mask: 0x0010
    """

    assert [
             %{type: :event, kind: :state_change, phys_addr: "1.0.0.0"},
             %{type: :event, kind: :state_change, phys_addr: "f.f.f.f", la_mask: 0},
             %{type: :event, kind: :other, text: "Lost 3 messages"},
             %{type: :event, kind: :state_change, phys_addr: "2.0.0.0"}
           ] = Parser.parse(out)
  end

  test "the verbose Sequence trailer completes a monitor record without waiting for more" do
    st = Parser.new()

    {st, []} =
      Parser.feed(st, "Received from TV to all (0 to 15): STANDBY (0x36)")

    {st, [%{opcode: "STANDBY", to: :all}]} =
      Parser.feed(st, "\tSequence: 4 Rx Timestamp: 1234.560000s")

    {st, []} =
      Parser.feed(
        st,
        "Received from Audio System to Playback Device 1 (5 to 4): REPORT_AUDIO_STATUS (0x7a):"
      )

    {st, []} = Parser.feed(st, "\taud-mute-status: Off (0x00)")
    {st, []} = Parser.feed(st, "\taud-vol-status: 20 (0x14)")
    {st, [audio]} = Parser.feed(st, "\tSequence: 5 Rx Timestamp: 1234.570000s")
    assert Parser.audio_status(audio) == %{volume: 20, muted: false}
    {_st, []} = Parser.finish(st)
  end

  describe "transmit_failures/1" do
    test "a delivered message, even one whose reply timed out, is no failure" do
      ok = """

      Transmit from Playback Device 1 to TV (4 to 0):
      IMAGE_VIEW_ON (0x04)
      \tSequence: 1 Tx Timestamp: 1234.000000s
      """

      reply_timeout = """

      Transmit from Playback Device 1 to Audio System (4 to 5):
      GIVE_DEVICE_POWER_STATUS (0x8f)
      \tSequence: 2 Tx Timestamp: 1234.100000s
      \tTx, OK, Rx, Timeout
      """

      assert Parser.transmit_failures(ok) == []
      assert Parser.transmit_failures(reply_timeout) == []
    end

    test "output without a transmit (driver info, a claim) has no failures" do
      assert Parser.transmit_failures("") == []
      assert Parser.transmit_failures("Driver Info:\n\tPhysical Address : 1.0.0.0\n") == []
    end

    test "a NACKed or arbitration-lost transmit is reported" do
      nack = """

      Transmit from Playback Device 1 to Audio System (4 to 5):
      STANDBY (0x36)
      \tSequence: 3 Tx Timestamp: 1234.200000s
      \tTx, Not Acknowledged (4), Max Retries
      """

      arb = """

      Transmit from Playback Device 1 to TV (4 to 0):
      IMAGE_VIEW_ON (0x04)
      \tSequence: 4 Tx Timestamp: 1234.300000s
      \tTx, Arbitration Lost (2), Max Retries
      """

      assert Parser.transmit_failures(nack) == ["Tx, Not Acknowledged (4), Max Retries"]
      assert Parser.transmit_failures(arb) == ["Tx, Arbitration Lost (2), Max Retries"]
    end

    test "a transmit whose ioctl failed (no Sequence line) is reported" do
      out = """

      Transmit from Playback Device 1 to TV (4 to 0):
      IMAGE_VIEW_ON (0x04)
      """

      assert Parser.transmit_failures(out) == ["not transmitted"]
    end

    test "every transmit in a multi-message invocation is checked" do
      out = """

      Transmit from Playback Device 1 to Audio System (4 to 5):
      USER_CONTROL_PRESSED (0x44):
      \tui-cmd: Volume Up (0x41)
      \tSequence: 5 Tx Timestamp: 1234.400000s

      Transmit from Playback Device 1 to Audio System (4 to 5):
      USER_CONTROL_RELEASED (0x45)
      \tSequence: 6 Tx Timestamp: 1234.500000s
      \tTx, Not Acknowledged (1), Max Retries
      """

      assert Parser.transmit_failures(out) == ["Tx, Not Acknowledged (1), Max Retries"]
    end
  end
end
