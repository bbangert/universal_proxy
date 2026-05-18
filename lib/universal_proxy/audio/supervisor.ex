defmodule UniversalProxy.Audio.Supervisor do
  @moduledoc """
  Top-level supervisor for the audio subsystem.

  Mirrors `UniversalProxy.UART.Supervisor`'s shape and uses
  `:rest_for_one` so that a crash anywhere in the dependency chain
  cascades cleanly downstream. Children in start order:

    1. `UniversalProxy.Audio.PlayerSupervisor` (DynamicSupervisor) —
       owns one `Audio.Player` GenServer per enabled ALSA output;
       populated at runtime by `Audio.Server` as outputs hotplug
       in/out and `set_enabled` toggles.
    2. `UniversalProxy.Audio.Store` — DETS-backed persistence for
       per-output config (`friendly_name`, `enabled`, `client_id`,
       `volume`, `muted`).
    3. `UniversalProxy.Audio.MdnsDiscovery` — placeholder GenServer
       providing the future Sendspin-server discovery contract;
       currently a stub (`current_server/0` → `:error`) because
       `mdns_lite 0.9.1` has no PTR browser.
    4. `UniversalProxy.Audio.Server` — the registry/orchestrator
       that polls enumeration, manages player lifecycle via the
       DynamicSupervisor above, and brokers PubSub events.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    # Order matters: PlayerSupervisor first (Server-mediated children
    # land here), then Store (Server reads/writes DETS), then
    # MdnsDiscovery (Server consults it for server URLs at player
    # spawn time), then Server itself. `:rest_for_one` so that a
    # crash anywhere in the dependency chain cascades downstream.
    children = [
      {DynamicSupervisor, name: UniversalProxy.Audio.PlayerSupervisor, strategy: :one_for_one},
      UniversalProxy.Audio.Store,
      UniversalProxy.Audio.MdnsDiscovery,
      UniversalProxy.Audio.Server
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
