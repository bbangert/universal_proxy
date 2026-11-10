defmodule UniversalProxy.ESPHome.Sendspin do
  @moduledoc """
  `Espex.Sendspin` adapter: reports the Sendspin client of the output
  selected in `UniversalProxy.Audio.HomeAssistantPairing`, so Home
  Assistant can read its pairing token and pair it with Music Assistant.

  Wired as `:sendspin` only while an output is selected (see
  `HomeAssistantPairing`). Both callbacks run in an Espex connection
  process, so every read is defensive: a down audio subsystem reads as no
  client id and `:not_ready`, never a crash.

  `pairing_token/0` answers, for the selected output:

    * `:not_ready` while it is unplugged, before its player has written a
      token, or while the audio subsystem is down
    * `:disabled` while it is turned off (or nothing is selected)
    * `:failed` while its player cannot persist its identity keypair
      (`Audio.Server`'s `identity_error`)
    * `{:ok, token}` otherwise

  The token is read from the player's state dir on every request
  (`UniversalProxy.Audio.pairing_token/1`) and never logged.
  """

  @behaviour Espex.Sendspin

  alias UniversalProxy.Audio
  alias UniversalProxy.Audio.HomeAssistantPairing

  @impl true
  def client_id do
    case selection() do
      {:ok, selection} -> client_id(selection)
      :error -> nil
    end
  end

  @impl true
  def pairing_token do
    case selection() do
      {:ok, %{key: key}} -> pairing_token(key, Audio)
      {:ok, nil} -> :disabled
      :error -> :not_ready
    end
  end

  @doc false
  @spec client_id(HomeAssistantPairing.selection() | nil) :: String.t() | nil
  def client_id(%{client_id: id}) when is_binary(id), do: id
  def client_id(_selection), do: nil

  @doc false
  # `audio` is `UniversalProxy.Audio` or a test stand-in with the same
  # `get_output/1` and `pairing_token/1`.
  @spec pairing_token(Audio.key(), module()) :: Espex.Sendspin.pairing_token_result()
  def pairing_token(key, audio) do
    case get_output(audio, key) do
      {:ok, %{enabled: false}} -> :disabled
      {:ok, %{identity_error: true}} -> :failed
      {:ok, _output} -> read_token(audio, key)
      :error -> :not_ready
    end
  end

  # A file that can't be read or doesn't hold a token is rewritten by the
  # player's next start, so it is not a permanent failure.
  defp read_token(audio, key) do
    case audio.pairing_token(key) do
      {:ok, token} -> {:ok, token}
      {:error, _reason} -> :not_ready
    end
  end

  defp get_output(audio, key) do
    audio.get_output(key)
  catch
    :exit, _reason -> :error
  end

  # Down, or the selection not loaded yet: unknown, not empty.
  defp selection do
    case HomeAssistantPairing.selection() do
      {:ok, selection} -> {:ok, selection}
      {:error, _reason} -> :error
    end
  catch
    :exit, _reason -> :error
  end
end
