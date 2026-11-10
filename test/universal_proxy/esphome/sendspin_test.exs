defmodule UniversalProxy.ESPHome.SendspinTest do
  # async: false — the stand-in reads its scripted answers from app env.
  use ExUnit.Case, async: false

  alias UniversalProxy.ESPHome.Sendspin

  @key {"bcm2835 Headphones", nil, nil}
  @token "SP:" <> String.duplicate("A", 104)

  defmodule AudioStub do
    @moduledoc false
    def get_output(_key) do
      case Application.get_env(:universal_proxy, :sendspin_test_output) do
        :exit -> exit(:noproc)
        result -> result
      end
    end

    def pairing_token(_key), do: Application.get_env(:universal_proxy, :sendspin_test_token)
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:universal_proxy, :sendspin_test_output)
      Application.delete_env(:universal_proxy, :sendspin_test_token)
    end)
  end

  defp token_for(output, token) do
    Application.put_env(:universal_proxy, :sendspin_test_output, output)
    Application.put_env(:universal_proxy, :sendspin_test_token, token)
    Sendspin.pairing_token(@key, AudioStub)
  end

  describe "pairing_token/2" do
    test "the token of an enabled output whose player wrote one" do
      assert {:ok, @token} = token_for({:ok, %{enabled: true}}, {:ok, @token})
    end

    test ":not_ready before the player has written a token, or when it is unreadable" do
      assert :not_ready = token_for({:ok, %{enabled: true}}, {:error, :not_ready})
      assert :not_ready = token_for({:ok, %{enabled: true}}, {:error, :unavailable})
    end

    test ":not_ready while the output is unplugged or the audio subsystem is down" do
      assert :not_ready = token_for(:error, {:ok, @token})
      assert :not_ready = token_for(:exit, {:ok, @token})
    end

    test ":disabled while the output is turned off, whatever its token" do
      assert :disabled = token_for({:ok, %{enabled: false}}, {:ok, @token})
    end

    test ":failed while the player can't persist its identity" do
      assert :failed = token_for({:ok, %{enabled: true, identity_error: true}}, {:ok, @token})
    end
  end

  describe "client_id/1" do
    test "the selection's cached client id, nil without one" do
      assert Sendspin.client_id(%{key: @key, client_id: "abc"}) == "abc"
      assert Sendspin.client_id(%{key: @key, client_id: nil}) == nil
      assert Sendspin.client_id(nil) == nil
    end
  end
end
