defmodule UniversalProxy.KmsgFilterTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.KmsgFilter

  @phrase "Unexpected advertising set terminated event"

  defp kmsg(msg, meta \\ %{application: :"$kmsg", facility: :kernel}),
    do: %{level: :warning, msg: {:string, msg}, meta: meta}

  test "drops the kernel event from any hciN" do
    assert :stop = KmsgFilter.filter(kmsg("Bluetooth: hci0: " <> @phrase), [])
    assert :stop = KmsgFilter.filter(kmsg("Bluetooth: hci1: " <> @phrase), [])
  end

  test "keeps other kernel lines" do
    assert :ignore = KmsgFilter.filter(kmsg("Bluetooth: hci0: command 0x2039 tx timeout"), [])
    assert :ignore = KmsgFilter.filter(kmsg("usb 1-1: new high-speed USB device"), [])
  end

  test "keeps a similar kernel line with extra text" do
    assert :ignore = KmsgFilter.filter(kmsg("Bluetooth: hci0: " <> @phrase <> " (handle 3)"), [])
  end

  test "keeps an application log that mentions the phrase" do
    app = %{application: :universal_proxy}
    assert :ignore = KmsgFilter.filter(kmsg("Bluetooth: hci0: " <> @phrase, app), [])
    assert :ignore = KmsgFilter.filter(kmsg("saw: " <> @phrase), [])
    assert :ignore = KmsgFilter.filter(kmsg("Bluetooth: hci0: " <> @phrase, %{}), [])
  end

  test "keeps non-string messages" do
    event = %{
      level: :info,
      msg: {:report, %{a: 1}},
      meta: %{application: :"$kmsg", facility: :kernel}
    }

    assert :ignore = KmsgFilter.filter(event, [])
  end

  test "install/0 is idempotent and registers the filter" do
    assert :ok = KmsgFilter.install()
    assert :ok = KmsgFilter.install()

    assert {_, _} =
             :logger.get_primary_config()
             |> Map.fetch!(:filters)
             |> List.keyfind(:drop_adv_set_terminated, 0)
  end
end
