defmodule Circuits.CEC.Adapter.Follower do
  @moduledoc false
  # The playback-device follower duties of `Circuits.CEC.Adapter`, as a pure
  # function from a received message to the replies to send and the state
  # changes to make.
  #
  # With a non-passthrough follower mode the kernel answers the core
  # messages itself (CEC version, physical address, OSD name, vendor ID,
  # Abort, Give Features) and never passes them on. Everything else that is
  # directed to us is ours to answer, and the kernel no longer
  # Feature-Aborts it for us.

  alias Circuits.CEC.Message

  @broadcast 15
  @unregistered 15

  @kernel_handled [
    :get_cec_version,
    :give_physical_address,
    :give_osd_name,
    :give_device_vendor_id,
    :abort,
    :give_features
  ]

  @forwardable [
    :give_deck_status,
    :play,
    :deck_control,
    :user_control_pressed,
    :user_control_released
  ]

  # Reports and notices: nothing to answer even when they are directed to
  # us (an AVR sends <Report Audio Status> after our volume keys, for
  # example). Feature-Aborting them would be noise at best.
  @informational [
    :feature_abort,
    :report_power_status,
    :report_audio_status,
    :set_system_audio_mode,
    :system_audio_mode_status,
    :cec_version,
    :set_osd_name,
    :device_vendor_id,
    :report_physical_address,
    :menu_status,
    :deck_status,
    :set_menu_language,
    :active_source,
    :inactive_source,
    :routing_change,
    :routing_information,
    :set_stream_path,
    :standby,
    :request_active_source
  ]

  @type context :: %{
          la: Message.logical_address() | nil,
          phys_addr: Message.physical_address(),
          active_source?: boolean(),
          power_status: atom(),
          handled: MapSet.t(atom())
        }

  @type reply :: {Message.logical_address(), Message.body()}
  @type effect :: {:active_source, boolean()} | {:standby, Message.logical_address()}

  @doc "Opcodes forwarded to subscribers that can claim them with `handle:`."
  @spec forwardable() :: [atom()]
  def forwardable, do: @forwardable

  @doc "Opcodes the kernel answers itself; we never reply to them."
  @spec kernel_handled() :: [atom()]
  def kernel_handled, do: @kernel_handled

  @doc """
  The replies (`{to, body}`, sent from `ctx.la`) and state effects for a
  received message.
  """
  @spec handle(Message.t(), context()) :: {[reply()], [effect()]}
  def handle(%Message{body: :poll}, _ctx), do: {[], []}

  def handle(%Message{} = msg, ctx) do
    {replies, effects} = duty(msg.body, msg, ctx)
    {Enum.filter(replies, &sendable?(&1, msg, ctx)), effects}
  end

  defp duty(:give_device_power_status, msg, ctx),
    do: {[{msg.from, {:report_power_status, ctx.power_status}}], []}

  defp duty(:request_active_source, _msg, %{active_source?: true} = ctx),
    do: {[{@broadcast, {:active_source, ctx.phys_addr}}], []}

  defp duty({:set_stream_path, pa}, _msg, %{phys_addr: pa, la: la} = ctx)
       when is_integer(la) and pa != 0xFFFF,
       do: {[{@broadcast, {:active_source, ctx.phys_addr}}], [{:active_source, true}]}

  defp duty({:set_stream_path, pa}, _msg, ctx), do: not_ours(pa, ctx)
  defp duty({:active_source, pa}, _msg, ctx), do: not_ours(pa, ctx)
  defp duty({:routing_information, pa}, _msg, ctx), do: not_ours(pa, ctx)
  defp duty({:routing_change, _orig, new}, _msg, ctx), do: not_ours(new, ctx)

  defp duty({:menu_request, _type}, msg, _ctx),
    do: {[{msg.from, {:menu_status, :deactivated}}], []}

  defp duty(:standby, msg, _ctx), do: {[], [{:standby, msg.from}, {:active_source, false}]}

  defp duty({:invalid, op, _operands}, msg, _ctx) do
    if Message.opcode_name(op) in (@kernel_handled ++ @informational),
      do: {[], []},
      else: {abort(msg, op, :invalid_operand), []}
  end

  defp duty({:unknown, op, _operands}, msg, _ctx), do: {abort(msg, op, :unrecognized_opcode), []}

  defp duty(body, msg, ctx) do
    name = name(body)

    cond do
      name in @kernel_handled or name in @informational -> {[], []}
      name in @forwardable and handled?(name, ctx) -> {[], []}
      true -> {abort(msg, name, :unrecognized_opcode), []}
    end
  end

  defp not_ours(pa, ctx) do
    if pa == ctx.phys_addr, do: {[], []}, else: {[], [{:active_source, false}]}
  end

  # <User Control Released> also belongs to whoever handles the press.
  defp handled?(:user_control_released, ctx),
    do:
      MapSet.member?(ctx.handled, :user_control_released) or
        MapSet.member?(ctx.handled, :user_control_pressed)

  defp handled?(name, ctx), do: MapSet.member?(ctx.handled, name)

  # Never answer a broadcast with <Feature Abort> or another directed reply.
  defp abort(%Message{to: @broadcast}, _op, _reason), do: []
  defp abort(msg, op, reason), do: [{msg.from, {:feature_abort, op, reason}}]

  defp name(body) when is_atom(body), do: body
  defp name(body) when is_tuple(body), do: elem(body, 0)

  # Replies need a logical address to send from. Directed replies go only
  # to a directed message for us from a registered device: a reply to
  # Unregistered (15) would be a broadcast. A broadcast <Active Source>
  # reaches everyone, so it answers a request from 15 too.
  defp sendable?(_reply, _msg, %{la: nil}), do: false
  defp sendable?({@broadcast, {:active_source, _pa}}, _msg, _ctx), do: true

  defp sendable?({_to, _body}, msg, ctx),
    do: msg.to == ctx.la and msg.from != @unregistered and msg.from != ctx.la
end
