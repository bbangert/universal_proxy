defmodule UniversalProxy.Audio.Input.Supervisor do
  @moduledoc """
  Top-level supervisor for the audio **input** (capture card) subsystem.

  The mirror image of `UniversalProxy.Audio.Supervisor`, and deliberately a
  sibling of it rather than an extra branch inside it: outputs and inputs
  share nothing but a naming scheme, so a crash on one side must not take
  the other down. Children in start order:

    1. `UniversalProxy.Audio.Input.SourceSupervisor` (DynamicSupervisor) —
       owns one `Audio.Input.Source` per present capture card; populated at
       runtime by `Audio.Input.Server` as cards hotplug in and out. Declared
       inline exactly like `Audio.PlayerSupervisor`: the name is the whole
       contract, there is no behaviour to put in a module.
    2. `UniversalProxy.Audio.Input.Store` — DETS-backed persistence for
       per-input config (`friendly_name`) and pairing state (client keypair,
       PSK, `paired_at`).
    3. `UniversalProxy.Audio.Input.Server` — the orchestrator that
       enumerates capture cards, manages source lifecycle through the
       DynamicSupervisor above, owns the `_sendspin._tcp` advertisement for
       each source, and brokers PubSub events.

  `:rest_for_one` for the same reason the output side uses it: Server
  depends on both the Store and the SourceSupervisor, so a crash upstream of
  it must cascade down to it (Server re-converges from scratch on restart),
  while a Server crash alone leaves the DETS file and the running sources
  untouched — `Audio.Input.Server.init/1` cleans up the orphaned sources
  itself.

  There is deliberately no `MdnsAnnouncer` here: `Audio.MdnsAnnouncer`
  re-announces *every* service registered with `MdnsLite`, source services
  included.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {DynamicSupervisor,
       name: UniversalProxy.Audio.Input.SourceSupervisor, strategy: :one_for_one},
      UniversalProxy.Audio.Input.Store,
      UniversalProxy.Audio.Input.Server
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
