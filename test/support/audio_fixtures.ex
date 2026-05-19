defmodule UniversalProxy.AudioFixtures do
  @moduledoc """
  Shared fixture helpers for audio-related LiveView and context tests.

  Extracted from per-test sample_output/1 builders so the production
  output map shape lives in exactly one place. A new required field on
  `Audio.list_outputs/0` then breaks the suites together rather than
  hiding behind a stale local builder in just one file.
  """

  @hp_key {"bcm2835 Headphones", nil, nil}

  @doc "Default key for the on-board 3.5 mm jack."
  def hp_key, do: @hp_key

  @doc """
  Build a sample merged output map matching `Audio.list_outputs/0`'s
  contract. Pass `overrides` to vary any field for a specific test.
  """
  @spec sample_output(map()) :: map()
  def sample_output(overrides \\ %{}) when is_map(overrides) do
    Map.merge(
      %{
        key: @hp_key,
        card_index: 0,
        alsa_device: "plughw:0,0",
        card_name: "bcm2835 Headphones",
        friendly_name: "Headphones",
        enabled: true,
        volume: 50,
        muted: false,
        client_id: "test-client-id"
      },
      overrides
    )
  end
end
