defmodule UniversalProxy.Storage.Supervisor do
  @moduledoc """
  Groups the USB-storage `DaemonSupervisor` and `Server` under
  `:one_for_all` (the `FMA120.Supervisor` precedent).

  If `Storage.Server` crashes, the `DaemonSupervisor` — and with it any
  running `smbd` — is torn down too. That matters more here than for a
  control-channel worker: an orphaned `smbd` would keep serving (and
  keep the mount point busy) for a drive the restarted Server knows
  nothing about, and it would still be listening on port 445 after the
  state that says "the share is opt-in and enabled" is gone. A fresh
  `Server` re-derives everything from `Probe` + `Settings` and starts its
  own daemon child.

  `Storage.Settings` is deliberately **not** a child here: it sits at the
  top level of `application.ex` so a crash in this subtree never closes
  its DETS file (the `FMA120.Store` rationale).

  Options are passed straight through to `Storage.Server`, which is where
  every test seam lives.
  """

  use Supervisor

  alias UniversalProxy.Storage

  @daemon_supervisor Storage.DaemonSupervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    daemon_supervisor = Keyword.get(opts, :daemon_supervisor, @daemon_supervisor)

    server_opts =
      opts
      |> Keyword.delete(:name)
      |> Keyword.put(:daemon_supervisor, daemon_supervisor)

    children = [
      # Declared inline exactly like `Audio.PlayerSupervisor`: the name is
      # the whole contract, there is no behaviour to put in a module.
      {DynamicSupervisor, name: daemon_supervisor, strategy: :one_for_one},
      {Storage.Server, server_opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
