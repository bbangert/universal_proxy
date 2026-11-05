defmodule UniversalProxy.Display.BindingTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Display.Binding

  @hdmi0 %{key: {"vc4-hdmi-0", nil, nil}, client_id: "h0", card_index: 1}
  @hdmi1 %{key: {"vc4-hdmi-1", nil, nil}, client_id: "h1", card_index: 2}
  @usb %{key: {"1-1.2", 0x1234, 0x5678}, client_id: "u", card_index: 3}
  @adapters [
    %{dev: "/dev/cec0", card_index: 1},
    %{dev: "/dev/cec1", card_index: 2},
    %{dev: "/dev/cecX", card_index: nil}
  ]

  test "follows the output whose player has the display roles" do
    outputs = [@usb, @hdmi0, Map.put(@hdmi1, :display_roles, true)]

    assert Binding.resolve(outputs, @adapters) ==
             %{key: @hdmi1.key, client_id: "h1", cec_dev: "/dev/cec1"}
  end

  test "falls back to the lowest-numbered HDMI output without roles" do
    assert %{key: {"vc4-hdmi-0", nil, nil}, cec_dev: "/dev/cec0"} =
             Binding.resolve([@usb, @hdmi1, @hdmi0], @adapters)
  end

  test "no CEC adapter on the output's card, or no card index" do
    assert %{cec_dev: nil} = Binding.resolve([@hdmi0], [])
    assert %{cec_dev: nil} = Binding.resolve([Map.delete(@hdmi0, :card_index)], @adapters)
  end

  test "nil without an HDMI output" do
    assert Binding.resolve([@usb], @adapters) == nil
    assert Binding.resolve([], @adapters) == nil
  end

  test "valid_phys_addr?/1" do
    assert Binding.valid_phys_addr?("1.0.0.0")
    refute Binding.valid_phys_addr?("f.f.f.f")
    refute Binding.valid_phys_addr?(nil)
  end
end
