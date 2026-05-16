defmodule UniversalProxy.FirmwareUpdate.Supervisor do
  @moduledoc """
  Library root supervisor for the firmware-update flow.

  The single public entry point the host imports. Hosting application
  child-specs this module (not `Updater` directly); at library
  extraction time the host swaps
  `UniversalProxy.FirmwareUpdate.Supervisor` → `NervesGithubUpdater.Supervisor`
  in one place.

  Accepts the same opts as `UniversalProxy.FirmwareUpdate.Updater.start_link/1`
  and passes them through to a single `Updater` child.
  """

  use Supervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    child_opts =
      opts
      |> Keyword.delete(:name)
      |> Keyword.put_new(:name, UniversalProxy.FirmwareUpdate.Updater)

    children = [{UniversalProxy.FirmwareUpdate.Updater, child_opts}]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
