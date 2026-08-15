defmodule UniversalProxy.FirmwareUpdate.Poller do
  @moduledoc """
  Periodically asks the updater to check GitHub for a newer release.

  Without this, nothing ever calls `UniversalProxy.FirmwareUpdate.check/0`
  on its own — `NervesGithubUpdater.Updater` arms no timers and does no
  check at boot, so `last_release` stays `nil` until someone presses Check
  in the web UI or Home Assistant. That leaves the HA `update.` entity
  reporting "up to date" indefinitely and the Settings → Updates panel
  empty.

  ## Jitter

  Both the startup delay and every subsequent interval are randomised.
  A fleet that loses power together would otherwise come back and hit the
  GitHub API in lockstep forever after — the startup jitter breaks up the
  initial stampede, and the per-interval jitter stops devices re-converging
  on a common phase over time.

  The first check is deliberately soon (minutes, not hours): a freshly
  flashed device should populate `last_release` early so HA has something
  to show, while still spreading load across the fleet.

  ## Cost

  Checks are cheap. The Updater sends `If-None-Match` with the stored
  ETag, so an unchanged release answers `304 Not Modified`, which GitHub
  does not count against the REST rate limit.

  Off-target (`MIX_TARGET=host`) `check/0` short-circuits to
  `{:error, :host_mode}`, so the poller doesn't schedule at all there.
  """

  use GenServer

  require Logger

  alias UniversalProxy.FirmwareUpdate

  # Mirrors the facade's own host check. Compile-time so deciding whether
  # to schedule costs nothing — and, critically, doesn't involve calling
  # check/0 (which would fire a real request just to probe the target).
  @host_mode Mix.target() == :host

  @default_interval_ms :timer.hours(24)

  # First check lands 1–15 min after boot: soon enough that a freshly
  # flashed device has a release to show, spread enough that a fleet
  # restarting together doesn't arrive at once.
  @startup_min_ms :timer.minutes(1)
  @startup_max_ms :timer.minutes(15)

  # ±10% on each subsequent interval, so devices don't re-converge on a
  # shared phase after the startup jitter wears off.
  @jitter_fraction 0.1

  @doc false
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl GenServer
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      check_fun: Keyword.get(opts, :check_fun, &FirmwareUpdate.check/0),
      rand_fun: Keyword.get(opts, :rand_fun, &:rand.uniform/1),
      timer: nil
    }

    # `enabled: false` (or host mode) keeps the process alive but idle, so
    # the supervision tree shape doesn't change between targets.
    if Keyword.get(opts, :enabled, enabled?()) do
      {:ok, schedule(state, startup_delay(state))}
    else
      {:ok, state}
    end
  end

  @impl GenServer
  def handle_info(:check, state) do
    case state.check_fun.() do
      :ok ->
        Logger.debug("FirmwareUpdate.Poller: periodic check requested")

      {:error, reason} ->
        # A rejected check (busy installing, host mode) is not fatal —
        # log and keep the cadence rather than stopping the loop.
        Logger.info("FirmwareUpdate.Poller: check rejected: #{inspect(reason)}")
    end

    {:noreply, schedule(state, next_delay(state))}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Exposed so tests can drive a tick without waiting on wall-clock time.
  @impl GenServer
  def handle_call(:check_now, _from, state) do
    {:reply, state.check_fun.(), state}
  end

  def handle_call(:next_delay, _from, state), do: {:reply, next_delay(state), state}

  # -- Scheduling --

  defp schedule(state, delay_ms) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :check, delay_ms)}
  end

  @doc false
  @spec startup_delay(map()) :: pos_integer()
  def startup_delay(%{rand_fun: rand_fun}) do
    @startup_min_ms + rand_fun.(@startup_max_ms - @startup_min_ms)
  end

  @doc false
  @spec next_delay(map()) :: pos_integer()
  def next_delay(%{interval_ms: interval_ms, rand_fun: rand_fun}) do
    spread = max(trunc(interval_ms * @jitter_fraction), 1)
    # rand_fun returns 1..2*spread, so the offset lands in -spread+1..+spread.
    max(interval_ms - spread + rand_fun.(2 * spread), 1)
  end

  defp enabled?, do: not @host_mode
end
