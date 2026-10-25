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
end
