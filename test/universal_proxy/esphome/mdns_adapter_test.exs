defmodule UniversalProxy.ESPHome.MdnsAdapterTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.ESPHome.MdnsAdapter

  describe "instance_name/1" do
    test "uses a non-blank node name verbatim as the service instance" do
      assert MdnsAdapter.instance_name("universal-proxy-45099b") == "universal-proxy-45099b"
    end

    test "falls back to :unspecified for blank/nil/non-binary names" do
      assert MdnsAdapter.instance_name("") == :unspecified
      assert MdnsAdapter.instance_name(nil) == :unspecified
      assert MdnsAdapter.instance_name(:oops) == :unspecified
    end
  end
end
