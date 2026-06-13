defmodule UniversalProxy.Bluetooth.Stats do
  @moduledoc """
  Live Bluetooth statistics for the web tab, broadcast as
  `{:bluetooth_stats, %{ads_per_s:, devices_15min:, connections:}}` on
  `UniversalProxy.Bluetooth.stats_topic()` every second (the
  `:uart_packet_rate` pattern):

    * `ads_per_s` — advertisements fanned out to HA in the last tick.
      Counted via `bump_ad/0` from
      `UniversalProxy.ESPHome.BluetoothScanner.on_advertisement/1`: an
      atomics `:counters` ref published through `:persistent_term`, so the
      advert hot path pays nanoseconds and never blocks on this server
      (and no-ops entirely when Stats isn't running — host, non-BT).
    * `devices_15min` — distinct devices seen in the last 15 minutes,
      a windowed count over `UniversalProxy.Bluez.DeviceCache`'s last-seen
      timestamps (via `UniversalProxy.Bluez.Client.devices_seen/1`).
    * `connections` — `%{used:, limit:}` GATT slots. Re-read each tick,
      plus `connections_changed/0` lets `UniversalProxy.Bluez.Gatt` push
      an off-tick update the moment a connection comes or goes.

  Every source is read defensively, so ticks keep flowing (with zeros)
  while the BlueZ subtree is down.
  """

  use GenServer

  alias UniversalProxy.Bluez.{Client, Gatt}

  @counter_key {__MODULE__, :ad_counter}
  @tick_ms 1_000
  @devices_window_ms 15 * 60 * 1000

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Count one advertisement. Called from the advert fan-out hot path —
  a `:persistent_term` read plus an atomic increment, and a no-op when
  Stats isn't running.
  """
  @spec bump_ad() :: :ok
  def bump_ad do
    case :persistent_term.get(@counter_key, nil) do
      nil -> :ok
      ref -> :counters.add(ref, 1, 1)
    end

    :ok
  end

  @doc "The most recently computed stats map (see `UniversalProxy.Bluetooth.stats/0`)."
  @spec current(GenServer.server()) :: map()
  def current(server \\ __MODULE__) do
    GenServer.call(server, :current)
  end

  @doc """
  Tell Stats the GATT connection count changed (fire-and-forget, from
  `UniversalProxy.Bluez.Gatt`): re-reads the slots and broadcasts
  immediately instead of waiting for the next tick.
  """
  @spec connections_changed(GenServer.server()) :: :ok
  def connections_changed(server \\ __MODULE__) do
    GenServer.cast(server, :connections_changed)
  end

  @impl GenServer
  def init(opts) do
    counter = :counters.new(1, [:write_concurrency])
    :persistent_term.put(@counter_key, counter)

    state = %{
      counter: counter,
      pubsub: Keyword.get(opts, :pubsub, UniversalProxy.PubSub),
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      devices_fun:
        Keyword.get(opts, :devices_fun, fn -> Client.devices_seen(@devices_window_ms) end),
      connections_fun: Keyword.get(opts, :connections_fun, &default_connections/0),
      last: %{
        ads_per_s: 0,
        devices_15min: 0,
        connections: %{used: 0, limit: Gatt.max_connections()}
      }
    }

    schedule(state)
    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, %{counter: counter}) do
    # Only un-publish our own ref — a restarted instance has already
    # replaced it, and erasing that one would silently stop the count.
    if :persistent_term.get(@counter_key, nil) == counter do
      :persistent_term.erase(@counter_key)
    end

    :ok
  end

  @impl GenServer
  def handle_call(:current, _from, state), do: {:reply, state.last, state}

  @impl GenServer
  def handle_cast(:connections_changed, state) do
    stats = %{state.last | connections: state.connections_fun.()}
    {:noreply, publish(state, stats)}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    stats = %{
      ads_per_s: read_and_reset(state.counter),
      devices_15min: state.devices_fun.(),
      connections: state.connections_fun.()
    }

    state = publish(state, stats)
    schedule(state)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Subtract what we read rather than zeroing, so bumps racing the read
  # aren't lost.
  defp read_and_reset(counter) do
    count = :counters.get(counter, 1)
    :counters.sub(counter, 1, count)
    count
  end

  defp publish(state, stats) do
    Phoenix.PubSub.broadcast(
      state.pubsub,
      UniversalProxy.Bluetooth.stats_topic(),
      {:bluetooth_stats, stats}
    )

    %{state | last: stats}
  end

  defp schedule(state), do: Process.send_after(self(), :tick, state.tick_ms)

  defp default_connections do
    {free, total} = Gatt.connections_free()
    %{used: total - free, limit: total}
  catch
    :exit, _ -> %{used: 0, limit: Gatt.max_connections()}
  end
end
