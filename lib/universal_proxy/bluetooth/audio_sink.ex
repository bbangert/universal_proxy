defmodule UniversalProxy.Bluetooth.AudioSink do
  @moduledoc """
  Presents connected A2DP headsets as Sendspin audio outputs, in the exact
  `%{key => info}` contract `UniversalProxy.Audio.Enumerate.safe/0` produces, so
  `UniversalProxy.Audio.Server` spawns players / allocates mDNS / tracks volume
  for them with no orchestrator changes.

  A headset keys by `{mac, nil, nil}` — the `vendor_id`/`product_id` slots are
  `nil` (it's not a USB card) and `mac` can't collide with an ALSA card's key
  (a card keys by USB bus path or card name, never a MAC). The info carries:

    * `:alsa_device` — `bluealsa:DEV=MAC,PROFILE=a2dp`, opened directly by
      sendspin (`--alsa-device`); no sendspin C change.
    * `:card_name`   — the BlueZ `Device1.Alias` (falls back to the MAC).
    * `:usb_port`    — `nil` (not a USB device).
    * `:card_index`  — `nil` (no `/proc/asound` card; it's a userspace PCM).

  `Audio.Server`/`Audio.Player` tolerate the `nil` `usb_port`/`card_index`
  (the player only reads `:alsa_device`); see Phase 2.4 of the plan.

  ## Failure tolerance

  `safe/0` mirrors `Enumerate.safe/0`: it rescues *any* failure and returns
  `%{}`, so it is inert when `bluealsad`/`org.bluealsa` is down or the
  `UniversalProxy.Bluez.BlueAlsa` client isn't running (off-target/CI). The
  composite enumerate then degrades to just the ALSA cards.
  """

  require Logger

  alias UniversalProxy.Bluez.BlueAlsa

  @type output_key :: {String.t(), nil, nil}
  @type output_info :: %{
          card_index: nil,
          alsa_device: String.t(),
          card_name: String.t(),
          usb_port: nil
        }

  @doc """
  Connected A2DP headsets as a `%{key => info}` map; `%{}` on any failure.
  """
  @spec safe() :: %{output_key() => output_info()}
  def safe do
    BlueAlsa.pcms()
    |> from_pcms()
  rescue
    e ->
      Logger.warning(
        "Bluetooth AudioSink enumerate failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      %{}
  end

  @doc """
  Pure shaper: turn a list of `UniversalProxy.Bluez.BlueAlsa.pcms/0` maps into
  the enumerate contract. Separated from `safe/0` so it's unit-testable from a
  fixture PCM list. Last-write-wins if a MAC appears twice (it shouldn't —
  one A2DP-playback PCM per connected headset).
  """
  @spec from_pcms([map()]) :: %{output_key() => output_info()}
  def from_pcms(pcms) when is_list(pcms) do
    Map.new(pcms, fn %{mac: mac, alsa_string: alsa_string} = pcm ->
      {{mac, nil, nil},
       %{
         card_index: nil,
         alsa_device: alsa_string,
         card_name: Map.get(pcm, :alias) || mac,
         usb_port: nil
       }}
    end)
  end
end
