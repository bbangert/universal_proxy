defmodule UniversalProxy.ESPHome.ZigbeeProxy.IdentityPusher do
  @moduledoc """
  Runs `UniversalProxy.ESPHome.ZigbeeProxy`'s `:on_change` fun off the
  owner, one call at a time.

  The owner sends `changed/1` after it publishes a new snapshot. Changes
  queued while a push runs are coalesced into one more run, and every
  run reads the latest snapshot itself, so a push never delivers an
  older state after a newer one. The owner links it at init and stops
  it in `terminate/2`.
  """

  use GenServer

  @spec start_link((-> term())) :: GenServer.on_start()
  def start_link(fun) when is_function(fun, 0), do: GenServer.start_link(__MODULE__, fun)

  @doc "Ask for a push of the current snapshot. Never blocks."
  @spec changed(pid()) :: :ok
  def changed(pid) do
    send(pid, :changed)
    :ok
  end

  @impl GenServer
  def init(fun), do: {:ok, fun}

  @impl GenServer
  def handle_info(:changed, fun) do
    drain_changed()
    _ = fun.()
    {:noreply, fun}
  end

  defp drain_changed do
    receive do
      :changed -> drain_changed()
    after
      0 -> :ok
    end
  end
end
