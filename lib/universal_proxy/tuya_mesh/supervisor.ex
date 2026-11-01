defmodule UniversalProxy.TuyaMesh.Supervisor do
  @moduledoc """
  The Tuya mesh subtree, mounted in the `Bluez` `extra_children:` slot
  (after the AudioManager pair, before `Improv.Supervisor`) only when a
  radio holds the `:tuya_mesh` role (see `UniversalProxy.Bluetooth.bluez_spec/1`).
  It sits after `Bluez.Radio`/`Bluez.Mgmt` and the Client, which the mesh
  Radio needs, so a restart of any of those (`:rest_for_one`) rebuilds it.

  Children, `:one_for_all`:

    1. a DynamicSupervisor (`UniversalProxy.TuyaMesh.MeshSupervisor`) the
       mesh (`UniversalProxy.TuyaMesh.Mesh`: Radio + Lights) runs under, as
       a `:temporary` child;
    2. `UniversalProxy.TuyaMesh.Resolver`, which starts and stops the mesh
       and publishes its status.

  `:one_for_all` because the Resolver tracks the one mesh it started: a
  restarted Resolver must not find a mesh it doesn't know about, and a
  restarted DynamicSupervisor must not leave the Resolver watching a dead
  one. Mesh faults stay inside: the mesh is temporary and the Resolver
  retries it, so they never reach this supervisor's restart budget, let
  alone the Bluez subtree's.

  Options: `:tuya_adapter` (the role MAC), `:name`, `:dynsup`, `:resolver`
  (the Resolver's name); everything else goes to the Resolver.
  """

  use Supervisor

  alias UniversalProxy.TuyaMesh.Resolver

  @dynsup UniversalProxy.TuyaMesh.MeshSupervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(opts) do
    dynsup = Keyword.get(opts, :dynsup, @dynsup)

    resolver_opts =
      opts
      |> Keyword.drop([:name, :resolver])
      |> Keyword.merge(dynsup: dynsup, name: Keyword.get(opts, :resolver, Resolver))

    Supervisor.init(
      [{DynamicSupervisor, name: dynsup, strategy: :one_for_one}, {Resolver, resolver_opts}],
      strategy: :one_for_all
    )
  end
end
