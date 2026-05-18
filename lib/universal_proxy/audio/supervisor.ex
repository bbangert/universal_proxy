defmodule UniversalProxy.Audio.Supervisor do
  @moduledoc """
  Top-level supervisor for the audio subsystem.

  Mirrors `UniversalProxy.UART.Supervisor`'s shape: a
  `DynamicSupervisor` for per-output `Audio.Player` processes
  (populated in Phase 3) followed by the `Audio.Store` DETS owner and
  the `Audio.Server` registry. Strategy is `:rest_for_one` so that a
  restart of the DynamicSupervisor cleanly tears down the store +
  server that hold references to the now-defunct player children.

  In Phase 1 the DynamicSupervisor sits empty — `Audio.Server` does
  not yet start `Audio.Player` children. The supervisor still owns
  the `PlayerSupervisor` registration so Phase 3 can wire players in
  without touching the application tree.
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
