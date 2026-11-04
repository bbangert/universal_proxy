defmodule Circuits.CEC.Message do
  @moduledoc """
  CEC message codec: bytes on the bus to and from tagged Elixir terms.

  A message is `%Circuits.CEC.Message{from: la, to: la, body: body}`. The
  wire format is the header byte (`from <<< 4 ||| to`, destination 15 =
  broadcast), the opcode and its operands, at most 16 bytes in all.
  Operand layouts follow the kernel's `<linux/cec-funcs.h>`.

  Bodies are an atom for messages without operands (`:standby`) or a tuple
  tagged with the message name (`{:active_source, 0x1000}`). Enumerated
  operands decode to atoms when known and stay integers otherwise, so every
  received byte is kept:

    * `:poll` - header only (no opcode), used for presence checks
    * `{:unknown, opcode, operands}` - an opcode this codec doesn't decode
    * `{:invalid, opcode, operands}` - a decoded opcode whose operands are
      too short (answer such a message with `<Feature Abort>` reason
      `:invalid_operand`)

  Operand bytes past the defined layout are ignored, as CEC requires for
  forward compatibility (`<User Control Pressed>` keeps them, since some UI
  commands carry extra operands).

  Physical addresses are 16-bit integers (`0x1000` is `1.0.0.0`; `0xFFFF`
  is invalid) and are big-endian on the wire.
  """

  import Bitwise

  @enforce_keys [:from, :to, :body]
  defstruct [:from, :to, :body]

  @typedoc "Logical address, 0..15. 15 is Unregistered as an initiator and Broadcast as a destination."
  @type logical_address :: 0..15

  @typedoc "Physical address `a.b.c.d` as a 16-bit integer."
  @type physical_address :: 0..0xFFFF

  @type body :: atom() | tuple()

  @type t :: %__MODULE__{from: logical_address(), to: logical_address(), body: body()}

  @broadcast 15
  @invalid_pa 0xFFFF

  @opcodes [
    feature_abort: 0x00,
    image_view_on: 0x04,
    tuner_step_increment: 0x05,
    tuner_step_decrement: 0x06,
    tuner_device_status: 0x07,
    give_tuner_device_status: 0x08,
    record_on: 0x09,
    record_status: 0x0A,
    record_off: 0x0B,
    text_view_on: 0x0D,
    record_tv_screen: 0x0F,
    give_deck_status: 0x1A,
    deck_status: 0x1B,
    set_menu_language: 0x32,
    clear_analogue_timer: 0x33,
    set_analogue_timer: 0x34,
    timer_status: 0x35,
    standby: 0x36,
    play: 0x41,
    deck_control: 0x42,
    timer_cleared_status: 0x43,
    user_control_pressed: 0x44,
    user_control_released: 0x45,
    give_osd_name: 0x46,
    set_osd_name: 0x47,
    set_osd_string: 0x64,
    set_timer_program_title: 0x67,
    system_audio_mode_request: 0x70,
    give_audio_status: 0x71,
    set_system_audio_mode: 0x72,
    set_audio_volume_level: 0x73,
    report_audio_status: 0x7A,
    give_system_audio_mode_status: 0x7D,
    system_audio_mode_status: 0x7E,
    routing_change: 0x80,
    routing_information: 0x81,
    active_source: 0x82,
    give_physical_address: 0x83,
    report_physical_address: 0x84,
    request_active_source: 0x85,
    set_stream_path: 0x86,
    device_vendor_id: 0x87,
    vendor_command: 0x89,
    vendor_remote_button_down: 0x8A,
    vendor_remote_button_up: 0x8B,
    give_device_vendor_id: 0x8C,
    menu_request: 0x8D,
    menu_status: 0x8E,
    give_device_power_status: 0x8F,
    report_power_status: 0x90,
    get_menu_language: 0x91,
    select_analogue_service: 0x92,
    select_digital_service: 0x93,
    set_digital_timer: 0x97,
    clear_digital_timer: 0x99,
    set_audio_rate: 0x9A,
    inactive_source: 0x9D,
    cec_version: 0x9E,
    get_cec_version: 0x9F,
    vendor_command_with_id: 0xA0,
    clear_ext_timer: 0xA1,
    set_ext_timer: 0xA2,
    report_short_audio_descriptor: 0xA3,
    request_short_audio_descriptor: 0xA4,
    give_features: 0xA5,
    report_features: 0xA6,
    request_current_latency: 0xA7,
    report_current_latency: 0xA8,
    initiate_arc: 0xC0,
    report_arc_initiated: 0xC1,
    report_arc_terminated: 0xC2,
    request_arc_initiation: 0xC3,
    request_arc_termination: 0xC4,
    terminate_arc: 0xC5,
    cdc_message: 0xF8,
    abort: 0xFF
  ]

  @logical_addresses [
    tv: 0,
    recording_1: 1,
    recording_2: 2,
    tuner_1: 3,
    playback_1: 4,
    audio_system: 5,
    tuner_2: 6,
    tuner_3: 7,
    playback_2: 8,
    recording_3: 9,
    tuner_4: 10,
    playback_3: 11,
    backup_1: 12,
    backup_2: 13,
    specific: 14,
    unregistered: 15
  ]

  @device_types [
    tv: 0,
    recording: 1,
    reserved: 2,
    tuner: 3,
    playback: 4,
    audio_system: 5,
    switch: 6,
    processor: 7
  ]

  @ui_commands [
    select: 0x00,
    up: 0x01,
    down: 0x02,
    left: 0x03,
    right: 0x04,
    right_up: 0x05,
    right_down: 0x06,
    left_up: 0x07,
    left_down: 0x08,
    device_root_menu: 0x09,
    device_setup_menu: 0x0A,
    contents_menu: 0x0B,
    favorite_menu: 0x0C,
    back: 0x0D,
    media_top_menu: 0x10,
    media_context_sensitive_menu: 0x11,
    number_entry_mode: 0x1D,
    number_11: 0x1E,
    number_12: 0x1F,
    number_0_or_number_10: 0x20,
    number_1: 0x21,
    number_2: 0x22,
    number_3: 0x23,
    number_4: 0x24,
    number_5: 0x25,
    number_6: 0x26,
    number_7: 0x27,
    number_8: 0x28,
    number_9: 0x29,
    dot: 0x2A,
    enter: 0x2B,
    clear: 0x2C,
    next_favorite: 0x2F,
    channel_up: 0x30,
    channel_down: 0x31,
    previous_channel: 0x32,
    sound_select: 0x33,
    input_select: 0x34,
    display_information: 0x35,
    help: 0x36,
    page_up: 0x37,
    page_down: 0x38,
    power: 0x40,
    volume_up: 0x41,
    volume_down: 0x42,
    mute: 0x43,
    play: 0x44,
    stop: 0x45,
    pause: 0x46,
    record: 0x47,
    rewind: 0x48,
    fast_forward: 0x49,
    eject: 0x4A,
    skip_forward: 0x4B,
    skip_backward: 0x4C,
    stop_record: 0x4D,
    pause_record: 0x4E,
    angle: 0x50,
    sub_picture: 0x51,
    video_on_demand: 0x52,
    electronic_program_guide: 0x53,
    timer_programming: 0x54,
    initial_configuration: 0x55,
    select_broadcast_type: 0x56,
    select_sound_presentation: 0x57,
    audio_description: 0x58,
    internet: 0x59,
    mode_3d: 0x5A,
    play_function: 0x60,
    pause_play_function: 0x61,
    record_function: 0x62,
    pause_record_function: 0x63,
    stop_function: 0x64,
    mute_function: 0x65,
    restore_volume_function: 0x66,
    tune_function: 0x67,
    select_media_function: 0x68,
    select_av_input_function: 0x69,
    select_audio_input_function: 0x6A,
    power_toggle_function: 0x6B,
    power_off_function: 0x6C,
    power_on_function: 0x6D,
    f1_blue: 0x71,
    f2_red: 0x72,
    f3_green: 0x73,
    f4_yellow: 0x74,
    f5: 0x75,
    data: 0x76
  ]

  @abort_reasons [
    unrecognized_opcode: 0,
    not_in_correct_mode: 1,
    cannot_provide_source: 2,
    invalid_operand: 3,
    refused: 4,
    unable_to_determine: 5
  ]

  @power_statuses [on: 0, standby: 1, to_on: 2, to_standby: 3]
  @on_off [off: 0, on: 1]
  @cec_versions [v1_3a: 4, v1_4: 5, v2_0: 6]
  @menu_request_types [activate: 0, deactivate: 1, query: 2]
  @menu_states [activated: 0, deactivated: 1]
  @status_requests [on: 1, off: 2, once: 3]
  @deck_control_modes [skip_forward: 1, skip_reverse: 2, stop: 3, eject: 4]

  @deck_info [
    play: 0x11,
    record: 0x12,
    play_reverse: 0x13,
    still: 0x14,
    slow: 0x15,
    slow_reverse: 0x16,
    fast_forward: 0x17,
    fast_reverse: 0x18,
    no_media: 0x19,
    stop: 0x1A,
    skip_forward: 0x1B,
    skip_reverse: 0x1C,
    index_search_forward: 0x1D,
    index_search_reverse: 0x1E,
    other: 0x1F
  ]

  @play_modes [
    play_reverse: 0x20,
    play_forward: 0x24,
    play_still: 0x25,
    fast_forward_min: 0x05,
    fast_forward_medium: 0x06,
    fast_forward_max: 0x07,
    fast_reverse_min: 0x09,
    fast_reverse_medium: 0x0A,
    fast_reverse_max: 0x0B,
    slow_forward_min: 0x15,
    slow_forward_medium: 0x16,
    slow_forward_max: 0x17,
    slow_reverse_min: 0x19,
    slow_reverse_medium: 0x1A,
    slow_reverse_max: 0x1B
  ]

  # Messages without operands.
  @no_operands [
    :image_view_on,
    :text_view_on,
    :request_active_source,
    :standby,
    :user_control_released,
    :give_device_power_status,
    :give_audio_status,
    :give_system_audio_mode_status,
    :give_physical_address,
    :give_osd_name,
    :get_cec_version,
    :give_device_vendor_id,
    :get_menu_language,
    :give_features,
    :abort
  ]

  # Messages whose only operand is a physical address.
  @pa_operand [:active_source, :inactive_source, :set_stream_path, :routing_information]

  # Messages whose only operand is one byte from a table (or a plain byte).
  @byte_operand [
    report_power_status: @power_statuses,
    set_system_audio_mode: @on_off,
    system_audio_mode_status: @on_off,
    cec_version: @cec_versions,
    menu_request: @menu_request_types,
    menu_status: @menu_states,
    give_deck_status: @status_requests,
    deck_status: @deck_info,
    play: @play_modes,
    deck_control: @deck_control_modes,
    set_audio_volume_level: []
  ]

  @decoded @no_operands ++
             @pa_operand ++
             Keyword.keys(@byte_operand) ++
             [
               :routing_change,
               :report_physical_address,
               :user_control_pressed,
               :report_audio_status,
               :system_audio_mode_request,
               :set_osd_name,
               :device_vendor_id,
               :feature_abort,
               :set_menu_language
             ]
  @decoded_opcodes Enum.map(@decoded, &Keyword.fetch!(@opcodes, &1))

  defguardp is_la(la) when is_integer(la) and la >= 0 and la <= 15
  defguardp is_pa(pa) when is_integer(pa) and pa >= 0 and pa <= 0xFFFF
  defguardp is_byte(b) when is_integer(b) and b >= 0 and b <= 0xFF

  @doc """
  Decodes a message from its bus bytes (the `msg` buffer of a `cec_msg`).

  Never raises: any 1–16 byte binary decodes, with unrecognised content in
  `{:unknown, _, _}` or `{:invalid, _, _}` bodies.

      iex> Circuits.CEC.Message.decode(<<0x4F, 0x82, 0x10, 0x00>>)
      {:ok, %Circuits.CEC.Message{from: 4, to: 15, body: {:active_source, 0x1000}}}
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, :invalid_length}
  def decode(<<from::4, to::4>>), do: {:ok, %__MODULE__{from: from, to: to, body: :poll}}

  def decode(<<from::4, to::4, opcode, operands::binary>>) when byte_size(operands) <= 14 do
    {:ok, %__MODULE__{from: from, to: to, body: decode_body(opcode, operands)}}
  end

  def decode(_bytes), do: {:error, :invalid_length}

  @doc """
  Encodes a message to its bus bytes.

      iex> Circuits.CEC.Message.encode(%Circuits.CEC.Message{from: 4, to: 0, body: :image_view_on})
      {:ok, <<0x40, 0x04>>}
  """
  @spec encode(t()) :: {:ok, binary()} | {:error, {:invalid_message, term()}}
  def encode(%__MODULE__{from: from, to: to, body: body} = message)
      when is_la(from) and is_la(to) do
    case encode_body(body) do
      {:ok, payload} when byte_size(payload) <= 15 -> {:ok, <<from::4, to::4, payload::binary>>}
      _ -> {:error, {:invalid_message, message}}
    end
  end

  def encode(other), do: {:error, {:invalid_message, other}}

  @doc "Like `encode/1`, but raises `ArgumentError` on an invalid message."
  @spec encode!(t()) :: binary()
  def encode!(message) do
    case encode(message) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise ArgumentError, "can't encode CEC message: #{inspect(reason)}"
    end
  end

  @doc "True if the message is addressed to every device (destination 15)."
  @spec broadcast?(t()) :: boolean()
  def broadcast?(%__MODULE__{to: to}), do: to == @broadcast

  ## Bodies

  for name <- @no_operands do
    op = Keyword.fetch!(@opcodes, name)
    defp decode_body(unquote(op), _operands), do: unquote(name)
  end

  for name <- @pa_operand do
    op = Keyword.fetch!(@opcodes, name)
    defp decode_body(unquote(op), <<pa::16, _::binary>>), do: {unquote(name), pa}
  end

  for {name, table} <- @byte_operand do
    op = Keyword.fetch!(@opcodes, name)

    defp decode_body(unquote(op), <<value, _::binary>>),
      do: {unquote(name), lookup(unquote(table), value)}
  end

  defp decode_body(0x80, <<orig::16, new::16, _::binary>>), do: {:routing_change, orig, new}

  defp decode_body(0x84, <<pa::16, type, _::binary>>),
    do: {:report_physical_address, pa, lookup(@device_types, type)}

  defp decode_body(0x44, <<cmd>>), do: {:user_control_pressed, lookup(@ui_commands, cmd)}

  defp decode_body(0x44, <<cmd, extra::binary>>),
    do: {:user_control_pressed, lookup(@ui_commands, cmd), extra}

  defp decode_body(0x7A, <<mute::1, volume::7, _::binary>>),
    do: {:report_audio_status, mute == 1, if(volume == 0x7F, do: :unknown, else: volume)}

  defp decode_body(0x70, <<>>), do: :system_audio_mode_request
  defp decode_body(0x70, <<pa::16, _::binary>>), do: {:system_audio_mode_request, pa}
  defp decode_body(0x47, <<name::binary>>) when name != <<>>, do: {:set_osd_name, name}
  defp decode_body(0x87, <<oui::24, _::binary>>), do: {:device_vendor_id, oui}

  defp decode_body(0x00, <<op, reason, _::binary>>),
    do: {:feature_abort, lookup(@opcodes, op), lookup(@abort_reasons, reason)}

  defp decode_body(0x32, <<lang::binary-3, _::binary>>), do: {:set_menu_language, lang}

  defp decode_body(op, operands) when op in @decoded_opcodes, do: {:invalid, op, operands}
  defp decode_body(op, operands), do: {:unknown, op, operands}

  defp encode_body(:poll), do: {:ok, <<>>}

  for name <- @no_operands do
    op = Keyword.fetch!(@opcodes, name)
    defp encode_body(unquote(name)), do: {:ok, <<unquote(op)>>}
  end

  for name <- @pa_operand do
    op = Keyword.fetch!(@opcodes, name)
    defp encode_body({unquote(name), pa}) when is_pa(pa), do: {:ok, <<unquote(op), pa::16>>}
  end

  for {name, table} <- @byte_operand do
    op = Keyword.fetch!(@opcodes, name)

    defp encode_body({unquote(name), value}) do
      with {:ok, byte} <- value(unquote(table), value), do: {:ok, <<unquote(op), byte>>}
    end
  end

  defp encode_body({:routing_change, orig, new}) when is_pa(orig) and is_pa(new),
    do: {:ok, <<0x80, orig::16, new::16>>}

  defp encode_body({:report_physical_address, pa, type}) when is_pa(pa) do
    with {:ok, byte} <- value(@device_types, type), do: {:ok, <<0x84, pa::16, byte>>}
  end

  defp encode_body({:user_control_pressed, cmd}) do
    with {:ok, byte} <- value(@ui_commands, cmd), do: {:ok, <<0x44, byte>>}
  end

  defp encode_body({:user_control_pressed, cmd, extra}) when is_binary(extra) do
    with {:ok, byte} <- value(@ui_commands, cmd), do: {:ok, <<0x44, byte, extra::binary>>}
  end

  defp encode_body({:report_audio_status, muted, volume}) when is_boolean(muted) do
    mute = if muted, do: 1, else: 0

    case volume do
      :unknown -> {:ok, <<0x7A, mute::1, 0x7F::7>>}
      v when is_integer(v) and v >= 0 and v <= 0x7F -> {:ok, <<0x7A, mute::1, v::7>>}
      _ -> :error
    end
  end

  defp encode_body(:system_audio_mode_request), do: {:ok, <<0x70>>}

  defp encode_body({:system_audio_mode_request, pa}) when is_pa(pa),
    do: {:ok, <<0x70, pa::16>>}

  defp encode_body({:set_osd_name, name})
       when is_binary(name) and byte_size(name) in 1..14,
       do: {:ok, <<0x47, name::binary>>}

  defp encode_body({:device_vendor_id, oui})
       when is_integer(oui) and oui >= 0 and oui <= 0xFFFFFF,
       do: {:ok, <<0x87, oui::24>>}

  defp encode_body({:feature_abort, op, reason}) do
    with {:ok, op_byte} <- value(@opcodes, op),
         {:ok, reason_byte} <- value(@abort_reasons, reason),
         do: {:ok, <<0x00, op_byte, reason_byte>>}
  end

  defp encode_body({:set_menu_language, lang}) when is_binary(lang) and byte_size(lang) == 3,
    do: {:ok, <<0x32, lang::binary>>}

  defp encode_body({tag, op, operands})
       when tag in [:unknown, :invalid] and is_byte(op) and is_binary(operands),
       do: {:ok, <<op, operands::binary>>}

  defp encode_body(_body), do: :error

  ## Opcodes

  @doc """
  The opcode of a message name or body. `nil` for `:poll`.

      iex> Circuits.CEC.Message.opcode(:give_device_power_status)
      0x8F
      iex> Circuits.CEC.Message.opcode({:active_source, 0x1000})
      0x82
      iex> Circuits.CEC.Message.opcode({:unknown, 0xA6, <<>>})
      0xA6
  """
  @spec opcode(body()) :: byte() | nil
  def opcode(:poll), do: nil
  def opcode({tag, op, _operands}) when tag in [:unknown, :invalid] and is_byte(op), do: op
  def opcode(body) when is_tuple(body), do: opcode(elem(body, 0))

  for {name, op} <- @opcodes do
    def opcode(unquote(name)), do: unquote(op)
  end

  @doc """
  The name of an opcode, or the opcode itself if it has none.

      iex> Circuits.CEC.Message.opcode_name(0x36)
      :standby
  """
  @spec opcode_name(byte()) :: atom() | byte()
  def opcode_name(op) when is_byte(op), do: lookup(@opcodes, op)

  @doc "True if `decode/1` decodes this opcode's operands (rather than `{:unknown, _, _}`)."
  @spec decoded_opcode?(byte()) :: boolean()
  def decoded_opcode?(op), do: op in @decoded_opcodes

  ## Addresses and operand constants

  @doc """
  The logical address for a name (`:tv`, `:audio_system`, `:playback_1`,
  ..., `:unregistered`, or `:broadcast`).

      iex> Circuits.CEC.Message.logical_address(:audio_system)
      5
  """
  @spec logical_address(atom()) :: logical_address()
  def logical_address(:broadcast), do: @broadcast

  for {name, la} <- @logical_addresses do
    def logical_address(unquote(name)), do: unquote(la)
  end

  @doc """
  The name of a logical address.

      iex> Circuits.CEC.Message.logical_address_name(4)
      :playback_1
  """
  @spec logical_address_name(logical_address()) :: atom()
  for {name, la} <- @logical_addresses do
    def logical_address_name(unquote(la)), do: unquote(name)
  end

  @doc """
  The primary device type operand value for a name, as in
  `<Report Physical Address>` and `cec_log_addrs.primary_device_type`.

      iex> Circuits.CEC.Message.device_type(:playback)
      4
  """
  @spec device_type(atom()) :: byte()
  for {name, value} <- @device_types do
    def device_type(unquote(name)), do: unquote(value)
  end

  @doc """
  The UI command code for a name, for `<User Control Pressed>`.

      iex> Circuits.CEC.Message.ui_command(:volume_up)
      0x41
  """
  @spec ui_command(atom()) :: byte()
  for {name, value} <- @ui_commands do
    def ui_command(unquote(name)), do: unquote(value)
  end

  @doc """
  Formats a physical address as `a.b.c.d` (hex digits).

      iex> Circuits.CEC.Message.pa_to_string(0x2100)
      "2.1.0.0"
      iex> Circuits.CEC.Message.pa_to_string(0xFFFF)
      "f.f.f.f"
  """
  @spec pa_to_string(physical_address()) :: String.t()
  def pa_to_string(pa) when is_pa(pa) do
    Enum.map_join([12, 8, 4, 0], ".", &Integer.to_string(pa >>> &1 &&& 0xF, 16))
    |> String.downcase()
  end

  @doc """
  Parses `a.b.c.d` (hex digits) into a physical address.

      iex> Circuits.CEC.Message.parse_pa("1.0.0.0")
      {:ok, 0x1000}
      iex> Circuits.CEC.Message.parse_pa("1.0.0")
      :error
  """
  @spec parse_pa(String.t()) :: {:ok, physical_address()} | :error
  def parse_pa(string) when is_binary(string) do
    with [_, _, _, _] = parts <- String.split(string, "."),
         nibbles when length(nibbles) == 4 <- Enum.flat_map(parts, &parse_nibble/1) do
      {:ok, Enum.reduce(nibbles, 0, &(&2 <<< 4 ||| &1))}
    else
      _ -> :error
    end
  end

  @doc """
  True for a usable physical address; `0xFFFF` (`f.f.f.f`) means the
  adapter has none (unplugged, or no EDID).
  """
  @spec valid_pa?(term()) :: boolean()
  def valid_pa?(pa), do: is_pa(pa) and pa != @invalid_pa

  ## Helpers

  defp parse_nibble(<<c>>) when c in ?0..?9, do: [c - ?0]
  defp parse_nibble(<<c>>) when c in ?a..?f, do: [c - ?a + 10]
  defp parse_nibble(<<c>>) when c in ?A..?F, do: [c - ?A + 10]
  defp parse_nibble(_other), do: []

  defp lookup(table, value) do
    case List.keyfind(table, value, 1) do
      {name, ^value} -> name
      nil -> value
    end
  end

  defp value(_table, value) when is_byte(value), do: {:ok, value}

  defp value(table, name) when is_atom(name) do
    case Keyword.fetch(table, name) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp value(_table, _value), do: :error
end
