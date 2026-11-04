defmodule Circuits.CEC.MessageTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Circuits.CEC.Message

  doctest Message

  # {bus bytes, from, to, body}: one or more rows per decoded opcode, with
  # operand layouts from <linux/cec-funcs.h>.
  @table [
    {<<0x44>>, 4, 4, :poll},
    {<<0x40, 0x04>>, 4, 0, :image_view_on},
    {<<0x40, 0x0D>>, 4, 0, :text_view_on},
    {<<0x0F, 0x85>>, 0, 15, :request_active_source},
    {<<0x0F, 0x36>>, 0, 15, :standby},
    {<<0x45, 0x45>>, 4, 5, :user_control_released},
    {<<0x04, 0x8F>>, 0, 4, :give_device_power_status},
    {<<0x45, 0x71>>, 4, 5, :give_audio_status},
    {<<0x45, 0x7D>>, 4, 5, :give_system_audio_mode_status},
    {<<0x04, 0x83>>, 0, 4, :give_physical_address},
    {<<0x04, 0x46>>, 0, 4, :give_osd_name},
    {<<0x04, 0x9F>>, 0, 4, :get_cec_version},
    {<<0x04, 0x8C>>, 0, 4, :give_device_vendor_id},
    {<<0x40, 0x91>>, 4, 0, :get_menu_language},
    {<<0x04, 0xA5>>, 0, 4, :give_features},
    {<<0x04, 0xFF>>, 0, 4, :abort},
    {<<0x4F, 0x82, 0x10, 0x00>>, 4, 15, {:active_source, 0x1000}},
    {<<0x40, 0x9D, 0x10, 0x00>>, 4, 0, {:inactive_source, 0x1000}},
    {<<0x0F, 0x86, 0x21, 0x00>>, 0, 15, {:set_stream_path, 0x2100}},
    {<<0x5F, 0x81, 0x21, 0x00>>, 5, 15, {:routing_information, 0x2100}},
    {<<0x0F, 0x80, 0x10, 0x00, 0x20, 0x00>>, 0, 15, {:routing_change, 0x1000, 0x2000}},
    {<<0x4F, 0x84, 0x10, 0x00, 0x04>>, 4, 15, {:report_physical_address, 0x1000, :playback}},
    {<<0x5F, 0x84, 0x20, 0x00, 0x05>>, 5, 15, {:report_physical_address, 0x2000, :audio_system}},
    {<<0x40, 0x90, 0x00>>, 4, 0, {:report_power_status, :on}},
    {<<0x04, 0x90, 0x01>>, 0, 4, {:report_power_status, :standby}},
    {<<0x04, 0x90, 0x02>>, 0, 4, {:report_power_status, :to_on}},
    {<<0x04, 0x90, 0x03>>, 0, 4, {:report_power_status, :to_standby}},
    {<<0x04, 0x90, 0x07>>, 0, 4, {:report_power_status, 7}},
    {<<0x5F, 0x72, 0x01>>, 5, 15, {:set_system_audio_mode, :on}},
    {<<0x54, 0x7E, 0x00>>, 5, 4, {:system_audio_mode_status, :off}},
    {<<0x04, 0x9E, 0x05>>, 0, 4, {:cec_version, :v1_4}},
    {<<0x04, 0x8D, 0x02>>, 0, 4, {:menu_request, :query}},
    {<<0x40, 0x8E, 0x01>>, 4, 0, {:menu_status, :deactivated}},
    {<<0x04, 0x1A, 0x03>>, 0, 4, {:give_deck_status, :once}},
    {<<0x40, 0x1B, 0x1A>>, 4, 0, {:deck_status, :stop}},
    {<<0x04, 0x41, 0x24>>, 0, 4, {:play, :play_forward}},
    {<<0x04, 0x42, 0x03>>, 0, 4, {:deck_control, :stop}},
    {<<0x45, 0x73, 0x2A>>, 4, 5, {:set_audio_volume_level, 42}},
    {<<0x45, 0x44, 0x41>>, 4, 5, {:user_control_pressed, :volume_up}},
    {<<0x45, 0x44, 0x43>>, 4, 5, {:user_control_pressed, :mute}},
    {<<0x40, 0x44, 0x6D>>, 4, 0, {:user_control_pressed, :power_on_function}},
    {<<0x04, 0x44, 0x60, 0x24>>, 0, 4, {:user_control_pressed, :play_function, <<0x24>>}},
    {<<0x04, 0x44, 0xFE>>, 0, 4, {:user_control_pressed, 0xFE}},
    {<<0x54, 0x7A, 0x2A>>, 5, 4, {:report_audio_status, false, 42}},
    {<<0x54, 0x7A, 0xE4>>, 5, 4, {:report_audio_status, true, 100}},
    {<<0x54, 0x7A, 0xFF>>, 5, 4, {:report_audio_status, true, :unknown}},
    {<<0x45, 0x70>>, 4, 5, :system_audio_mode_request},
    {<<0x45, 0x70, 0x10, 0x00>>, 4, 5, {:system_audio_mode_request, 0x1000}},
    {<<0x40, 0x47, "Universal">>, 4, 0, {:set_osd_name, "Universal"}},
    {<<0x0F, 0x87, 0x00, 0x00, 0xF0>>, 0, 15, {:device_vendor_id, 0x0000F0}},
    {<<0x40, 0x00, 0x8F, 0x00>>, 4, 0,
     {:feature_abort, :give_device_power_status, :unrecognized_opcode}},
    {<<0x40, 0x00, 0x8D, 0x03>>, 4, 0, {:feature_abort, :menu_request, :invalid_operand}},
    {<<0x40, 0x00, 0x01, 0x09>>, 4, 0, {:feature_abort, 0x01, 9}},
    {<<0x0F, 0x32, "eng">>, 0, 15, {:set_menu_language, "eng"}},
    {<<0x04, 0xA6, 0x01, 0x02>>, 0, 4, {:unknown, 0xA6, <<0x01, 0x02>>}},
    {<<0x04, 0x89, 0xDE, 0xAD>>, 0, 4, {:unknown, 0x89, <<0xDE, 0xAD>>}},
    {<<0x04, 0x01>>, 0, 4, {:unknown, 0x01, <<>>}}
  ]

  describe "encode/decode table" do
    test "every row decodes and encodes" do
      for {bytes, from, to, body} <- @table do
        message = %Message{from: from, to: to, body: body}
        assert Message.decode(bytes) == {:ok, message}, inspect(bytes)
        assert Message.encode(message) == {:ok, bytes}, inspect(message)
      end
    end

    test "covers every decoded opcode" do
      covered =
        for {<<_header, op, _::binary>>, _, _, body} <- @table,
            not match?({:unknown, _, _}, body),
            uniq: true,
            do: op

      missing = for op <- 0..255, Message.decoded_opcode?(op), op not in covered, do: op
      assert missing == []
    end

    test "names and numbers are both accepted for enumerated operands" do
      assert Message.encode(%Message{from: 4, to: 0, body: {:report_power_status, 0}}) ==
               {:ok, <<0x40, 0x90, 0x00>>}

      assert Message.encode(%Message{from: 4, to: 5, body: {:user_control_pressed, 0x41}}) ==
               {:ok, <<0x45, 0x44, 0x41>>}

      assert Message.encode(%Message{from: 4, to: 0, body: {:feature_abort, 0x8F, 0}}) ==
               {:ok, <<0x40, 0x00, 0x8F, 0x00>>}
    end
  end

  describe "decode edge cases" do
    test "operands past the defined layout are ignored" do
      assert {:ok, %Message{body: :give_device_power_status}} =
               Message.decode(<<0x04, 0x8F, 0xAA>>)

      assert {:ok, %Message{body: {:active_source, 0x1000}}} =
               Message.decode(<<0x4F, 0x82, 0x10, 0x00, 0x99>>)

      assert {:ok, %Message{body: {:report_power_status, :standby}}} =
               Message.decode(<<0x04, 0x90, 0x01, 0x00>>)
    end

    test "short operands of a decoded opcode are :invalid" do
      for {bytes, op, operands} <- [
            {<<0x0F, 0x82, 0x10>>, 0x82, <<0x10>>},
            {<<0x0F, 0x80, 0x10, 0x00, 0x20>>, 0x80, <<0x10, 0x00, 0x20>>},
            {<<0x40, 0x90>>, 0x90, <<>>},
            {<<0x45, 0x70, 0x10>>, 0x70, <<0x10>>},
            {<<0x40, 0x47>>, 0x47, <<>>},
            {<<0x40, 0x44>>, 0x44, <<>>},
            {<<0x40, 0x00, 0x8F>>, 0x00, <<0x8F>>},
            {<<0x0F, 0x32, "en">>, 0x32, "en"},
            {<<0x0F, 0x87, 0x00, 0x00>>, 0x87, <<0, 0>>}
          ] do
        assert {:ok, %Message{body: {:invalid, ^op, ^operands}} = message} =
                 Message.decode(bytes)

        assert Message.encode(message) == {:ok, bytes}
      end
    end

    test "lengths outside 1..16" do
      assert Message.decode(<<>>) == {:error, :invalid_length}
      assert Message.decode(:binary.copy(<<0>>, 17)) == {:error, :invalid_length}
      assert {:ok, _} = Message.decode(:binary.copy(<<0x40>>, 16))
    end
  end

  describe "encode errors" do
    test "invalid messages" do
      for message <- [
            %Message{from: 16, to: 0, body: :image_view_on},
            %Message{from: 4, to: -1, body: :image_view_on},
            %Message{from: 4, to: 0, body: :bogus},
            %Message{from: 4, to: 15, body: {:active_source, 0x10000}},
            %Message{from: 4, to: 0, body: {:set_osd_name, ""}},
            %Message{from: 4, to: 0, body: {:set_osd_name, "123456789012345"}},
            %Message{from: 4, to: 5, body: {:user_control_pressed, :nope}},
            %Message{from: 4, to: 5, body: {:report_audio_status, false, 128}},
            %Message{from: 4, to: 0, body: {:feature_abort, :standby, :whatever}},
            %Message{from: 4, to: 0, body: {:unknown, 0x89, :binary.copy(<<0>>, 15)}}
          ] do
        assert {:error, {:invalid_message, ^message}} = Message.encode(message)
      end

      assert {:error, {:invalid_message, :nope}} = Message.encode(:nope)
    end

    test "encode! raises" do
      assert_raise ArgumentError, fn ->
        Message.encode!(%Message{from: 4, to: 0, body: :bogus})
      end
    end
  end

  describe "helpers" do
    test "opcodes" do
      assert Message.opcode({:feature_abort, :standby, :refused}) == 0x00
      assert Message.opcode({:invalid, 0x82, <<>>}) == 0x82
      assert Message.opcode(:poll) == nil
      assert Message.opcode_name(0x8F) == :give_device_power_status
      assert Message.opcode_name(0x01) == 0x01
      refute Message.decoded_opcode?(0xA6)
    end

    test "logical addresses" do
      assert Message.logical_address(:tv) == 0
      assert Message.logical_address(:playback_1) == 4
      assert Message.logical_address(:broadcast) == 15
      assert Message.logical_address(:unregistered) == 15
      assert Enum.map(0..15, &Message.logical_address_name/1) |> Enum.uniq() |> length() == 16
    end

    test "broadcast?" do
      assert Message.broadcast?(%Message{from: 4, to: 15, body: :standby})
      refute Message.broadcast?(%Message{from: 4, to: 5, body: :standby})
    end

    test "physical addresses" do
      assert Message.pa_to_string(0x0000) == "0.0.0.0"
      assert Message.pa_to_string(0x12AB) == "1.2.a.b"
      assert Message.parse_pa("1.2.A.b") == {:ok, 0x12AB}
      assert Message.parse_pa("f.f.f.f") == {:ok, 0xFFFF}
      assert Message.parse_pa("1.0.0.0.0") == :error
      assert Message.parse_pa("1.0.0.g") == :error
      assert Message.parse_pa("10.0.0.0") == :error
      assert Message.parse_pa("") == :error
      assert Message.valid_pa?(0x0000)
      assert Message.valid_pa?(0x1000)
      refute Message.valid_pa?(0xFFFF)
      refute Message.valid_pa?(-1)
      refute Message.valid_pa?(nil)
    end
  end

  describe "properties" do
    property "decode never raises on 1..16 bytes, and re-encodes to the same message" do
      check all(bytes <- binary(min_length: 1, max_length: 16)) do
        assert {:ok, message} = Message.decode(bytes)
        assert {:ok, encoded} = Message.encode(message)
        assert Message.decode(encoded) == {:ok, message}
      end
    end

    property "decode(encode(m)) == m and the bytes are exact for canonical messages" do
      check all(
              header <- integer(0..255),
              {op, operands} <- canonical_payload()
            ) do
        bytes = <<header, op, operands::binary>>
        assert {:ok, message} = Message.decode(bytes)
        refute match?({:invalid, _, _}, message.body)
        assert Message.encode(message) == {:ok, bytes}
        assert Message.decode(Message.encode!(message)) == {:ok, message}
      end
    end

    property "physical addresses round-trip through strings" do
      check all(pa <- integer(0..0xFFFF)) do
        assert pa |> Message.pa_to_string() |> Message.parse_pa() == {:ok, pa}
      end
    end
  end

  @no_operands [0x04, 0x0D, 0x85, 0x36, 0x45, 0x8F, 0x71, 0x7D, 0x83, 0x46, 0x9F, 0x8C, 0x91]
  @no_operands @no_operands ++ [0xA5, 0xFF]
  @pa_operand [0x82, 0x9D, 0x86, 0x81]
  @byte_operand [0x90, 0x72, 0x7E, 0x9E, 0x8D, 0x8E, 0x1A, 0x1B, 0x41, 0x42, 0x73]

  # Operands of exactly the defined layout for each decoded opcode, plus
  # anything for an opcode the codec doesn't decode.
  defp canonical_payload do
    one_of([
      tuple({member_of(@no_operands), constant(<<>>)}),
      tuple({member_of(@pa_operand), binary(length: 2)}),
      tuple({member_of(@byte_operand), binary(length: 1)}),
      tuple({constant(0x80), binary(length: 4)}),
      tuple({constant(0x84), binary(length: 3)}),
      tuple({constant(0x44), binary(min_length: 1, max_length: 14)}),
      tuple({constant(0x7A), binary(length: 1)}),
      tuple({constant(0x70), one_of([constant(<<>>), binary(length: 2)])}),
      tuple({constant(0x47), binary(min_length: 1, max_length: 14)}),
      tuple({constant(0x87), binary(length: 3)}),
      tuple({constant(0x00), binary(length: 2)}),
      tuple({constant(0x32), binary(length: 3)}),
      tuple({
        filter(integer(0..255), &(not Message.decoded_opcode?(&1))),
        binary(max_length: 14)
      })
    ])
  end
end
