defmodule UniversalProxy.Audio.Enumerate.Composite do
  @moduledoc """
  Composite audio enumerate source: the union of the local ALSA cards
  (`UniversalProxy.Audio.Enumerate`) and connected A2DP headsets
  (`UniversalProxy.Bluetooth.AudioSink`).

  This is what `:audio_enumerate_module` points at on the BT targets, so
  `UniversalProxy.Audio.Server` treats a Bluetooth headset as just another
  discoverable output — same player spawn, mDNS allocation, volume and
  connection tracking, no orchestrator change.

  Keys cannot collide: ALSA cards key by `{usb_port | card_name, vid, pid}`
  and headsets by `{mac, nil, nil}`; a MAC is never a USB bus path or card
  name. Both sources are individually `safe` (each rescues to `%{}`), so the
  union degrades gracefully — if the BT side is down you still get the ALSA
  cards, and vice versa.
  """

  alias UniversalProxy.Audio.Enumerate
  alias UniversalProxy.Bluetooth.AudioSink

  # Default source modules, each exposing a `safe/0` that returns a
  # `%{key => info}` map and never raises. Overridable in tests.
  @sources [Enumerate, AudioSink]

  @doc """
  Union of ALSA-card outputs and connected-headset outputs.

  `sources` defaults to the real `Enumerate` + `AudioSink` modules and exists
  so tests can inject stubs. Later sources win on a key clash, but the key
  shapes are disjoint by construction so no clash occurs in practice.
  """
  @spec safe([module()]) :: %{(Enumerate.output_key() | AudioSink.output_key()) => map()}
  def safe(sources \\ @sources) do
    Enum.reduce(sources, %{}, fn mod, acc -> Map.merge(acc, mod.safe()) end)
  end
end
