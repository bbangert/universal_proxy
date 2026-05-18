defmodule UniversalProxy.Audio.MdnsDiscovery do
  @moduledoc """
  Sendspin-server discovery via mDNS — Phase 3 **stub**.

  `Audio.Player` needs an initial `ws://…` URL to point its WebSocket
  reconnect loop at. The plan called for a `mdns_lite` browser
  watching `_sendspin-server._tcp.local.`, but `mdns_lite 0.9.1`
  (current pin via `nerves_pack`) exposes only advertising and
  hostname-resolution APIs — there is no PTR browser yet.

  This module ships the public interface (`current_server/0`)
  expected by `Audio.Server`, but `current_server/0` returns
  `:error` until a real implementation arrives. `Audio.Player`
  treats `:error` as "no server known"; the binary's own reconnect
  loop sits idle until the Phase 4 LiveView lets a user enter a URL
  manually or until this module learns to browse.

  ## Replacement paths

    * **Polling browser:** call `MdnsLite.query/2` with a hand-rolled
      PTR query for `_sendspin-server._tcp.local.` every N seconds,
      walk the SRV/A records, populate an ETS cache.
    * **`mdns_lite` upgrade:** if 0.10+ adds browsing, swap to it.
    * **User-entered server URL:** Phase 4 form field that sets a
      per-output `server_url` in DETS.

  Whichever path lands first, the contract here stays the same:
  `current_server/0` → `{:ok, url} | :error`.
  """

  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Return the best-known Sendspin server URL, or `:error` if none.
  Stub: always returns `:error` until the browser ships.
  """
  @spec current_server() :: {:ok, String.t()} | :error
  def current_server, do: current_server(__MODULE__)

  @spec current_server(GenServer.server()) :: {:ok, String.t()} | :error
  def current_server(server), do: GenServer.call(server, :current_server)

  @impl true
  def init(_opts) do
    Logger.info("Audio.MdnsDiscovery started (stub — mdns_lite 0.9.1 has no PTR browser)")

    {:ok, %{servers: %{}}}
  end

  @impl true
  def handle_call(:current_server, _from, state) do
    # Future: pick the most-recently-seen server from state.servers.
    {:reply, :error, state}
  end
end
