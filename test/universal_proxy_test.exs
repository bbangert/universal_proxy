defmodule UniversalProxyTest do
  use ExUnit.Case
  doctest UniversalProxy

  test "greets the world" do
    assert UniversalProxy.hello() == :nerves
  end
end
