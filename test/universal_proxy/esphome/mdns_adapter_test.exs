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

  describe "host_alias/1" do
    test "accepts the default MAC-suffixed node name" do
      assert MdnsAdapter.host_alias("universal-proxy-07507f") == "universal-proxy-07507f"
    end

    test "accepts a single-character and mixed-case name" do
      assert MdnsAdapter.host_alias("a") == "a"
      assert MdnsAdapter.host_alias("My-Proxy2") == "My-Proxy2"
    end

    test "rejects names that are not valid DNS host labels" do
      # RFC 1123 labels: letters/digits/hyphens, no edge hyphens, ≤ 63 bytes.
      # An invalid name means NO alias rather than an invalid mDNS record.
      assert MdnsAdapter.host_alias("has space") == nil
      assert MdnsAdapter.host_alias("under_score") == nil
      assert MdnsAdapter.host_alias("-leading") == nil
      assert MdnsAdapter.host_alias("trailing-") == nil
      assert MdnsAdapter.host_alias("dotted.name") == nil
      assert MdnsAdapter.host_alias(String.duplicate("x", 64)) == nil
      assert MdnsAdapter.host_alias("") == nil
      assert MdnsAdapter.host_alias(nil) == nil
      assert MdnsAdapter.host_alias(:oops) == nil
    end
  end
end
