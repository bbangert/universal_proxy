defmodule UniversalProxy.Audio.NullEnumerate do
  @moduledoc """
  Drop-in replacement for `UniversalProxy.Audio.Enumerate` that always
  reports an empty output set.

  Used by `config :universal_proxy, :audio_enumerate_module, ...` in
  `config/test.exs` so the application-tree `Audio.Server` singleton
  doesn't try to fork real `sendspin_player` binaries when `mix test`
  runs on a host that happens to have ALSA outputs in
  `/proc/asound/cards`. Focused audio tests still supply their own
  `enumerate_module:` opt to drive Server with deterministic
  enumeration.
  """

  @spec safe() :: %{}
  def safe, do: %{}
end
