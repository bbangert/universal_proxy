defmodule UniversalProxy.KmsgFilter do
  @moduledoc """
  `:logger` primary filter that drops one known-harmless kernel message.

  Some Bluetooth controllers (e.g. the Realtek RTL8761B in the TP-Link UB500)
  send an LE Advertising Set Terminated event with status 0x44 "Cancelled by
  Host" whenever the host disables an advertising set, which the Core spec says
  a controller must not do. The kernel ignores the event but logs
  `Bluetooth: hciN: Unexpected advertising set terminated event` each time, and
  the Tuya mesh radio disables its advertising instance after every frame.

  Only events that came from the kernel log tailer (`application: :"$kmsg"`,
  `facility: :kernel`) and match that exact message are dropped; an
  application log that merely mentions the phrase is kept.
  """

  @pattern ~r/\ABluetooth: hci\d+: Unexpected advertising set terminated event\z/

  @doc """
  Installs the filter as a primary `:logger` filter. Idempotent.
  """
  @spec install() :: :ok
  def install do
    case :logger.add_primary_filter(:drop_adv_set_terminated, {&filter/2, []}) do
      :ok -> :ok
      {:error, {:already_exist, _}} -> :ok
    end
  end

  @doc """
  `:logger` filter callback: `:stop` for the noisy kernel event, `:ignore`
  (defer to other filters) otherwise.
  """
  @spec filter(:logger.log_event(), term()) :: :stop | :ignore
  def filter(%{msg: {:string, msg}, meta: %{application: :"$kmsg", facility: :kernel}}, _extra)
      when is_binary(msg) do
    if Regex.match?(@pattern, String.trim_trailing(msg)), do: :stop, else: :ignore
  end

  def filter(_event, _extra), do: :ignore
end
