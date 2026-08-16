defmodule UniversalProxy.Sendspin.ClockFilter do
  @moduledoc """
  Two-state (offset + drift) Kalman filter for NTP-style clock
  synchronisation with a Sendspin server.

  A pure struct + functions; no process. The connection GenServer owns
  one filter per connection, feeds it every `server/time` reply, and
  uses `server_time/2` to stamp outgoing audio frames.

  ## Reference implementations

  Ported 1:1 from the upstream filter rather than tuned locally:

  * `aiosendspin/client/time_sync.py` (`SendspinTimeFilter`) and
    `aiosendspin/client/connection.py` (`_handle_server_time`,
    `is_time_synchronized`) — github.com/Sendspin/aiosendspin @ `main`,
    read 2026-08-16.
  * `src/time_filter.{h,cpp}` (`sendspin::SendspinTimeFilter`) —
    github.com/Sendspin/sendspin-cpp @ tag `v0.7.2`.

  The two agree on state model, noise parameters and conversions;
  aiosendspin is treated as authoritative where they differ (see
  "Deviations" below).

  ## Model

  State is `[offset, drift]` with a full 2x2 covariance, where

      server_time(t) = t + offset + drift * (t - last_update)

  `drift` is dimensionless (µs of offset per µs of elapsed time).
  Each `server/time` exchange yields an NTP measurement pair

      measurement = ((T2 - T1) + (T3 - T4)) / 2
      max_error   = ((T4 - T1) - (T3 - T2)) / 2

  with T1 = client_transmitted, T2 = server_received,
  T3 = server_transmitted, T4 = client_received.

  ## Outlier handling

  There is no hard RTT reject. `max_error` (half the round-trip delay)
  *is* the measurement standard deviation — scaled by
  `:max_error_scale`, because the half-delay overestimates true noise —
  so a sample taken across a latency spike gets a proportionally tiny
  Kalman gain and barely moves the estimate. Once `:min_samples`
  history exists, a residual beyond `:adaptive_cutoff * max_error`
  additionally inflates the covariances by `:forget_factor ** 2` so the
  filter can re-converge after a genuine server clock step. Out-of-order
  or duplicate measurements (`time_added` not strictly increasing) are
  dropped outright.

  ## Clock basis

  Basis-agnostic: it only maps caller-supplied local µs to server µs.
  The caller must use ONE basis for both the `client/time` exchange
  (T1/T4) and for frame stamping. The connection GenServer uses
  `System.monotonic_time(:microsecond)` — monotonic, never slewed by
  NTP, which matches aiosendspin's `CLOCK_MONOTONIC_RAW` clock and is
  what keeps the drift term meaningful.

  ## Deviations from aiosendspin

  * `last_update` starts as `nil` rather than `0`. BEAM monotonic time
    legitimately starts negative, and the reference's `time_added <= 0`
    guard would reject every sample on such a clock.
  * Unbounded initial offset covariance is `nil` rather than `math.inf`
    (no float infinity on the BEAM); `error/1` returns `:infinity`
    there instead of raising.
  * `update/5` folds the connection-level measurement derivation
    (`_handle_server_time`) into this module; `update_measurement/4` is
    the reference's raw `update` entry point.
  """

  @type t :: %__MODULE__{
          count: non_neg_integer(),
          last_update: integer() | nil,
          offset: float(),
          drift: float(),
          offset_covariance: float() | nil,
          offset_drift_covariance: float(),
          drift_covariance: float(),
          use_drift: boolean(),
          process_variance: float(),
          drift_process_variance: float(),
          forget_variance_factor: float(),
          adaptive_cutoff: float(),
          max_error_scale: float(),
          min_samples: pos_integer(),
          drift_significance_threshold_squared: float()
        }

  defstruct count: 0,
            last_update: nil,
            offset: 0.0,
            drift: 0.0,
            offset_covariance: nil,
            offset_drift_covariance: 0.0,
            drift_covariance: 0.0,
            use_drift: false,
            process_variance: 0.0,
            drift_process_variance: 1.0e-22,
            forget_variance_factor: 4.0,
            adaptive_cutoff: 3.0,
            max_error_scale: 0.5,
            min_samples: 100,
            drift_significance_threshold_squared: 4.0

  @doc """
  Build a filter with the upstream default tuning.

  Options (all upstream `Config` fields, same defaults):

  * `:process_std_dev` (`0.0`) — offset random-walk diffusion,
    µs/sqrt(µs).
  * `:drift_process_std_dev` (`1.0e-11`) — drift random-walk diffusion,
    1/sqrt(µs).
  * `:forget_factor` (`2.0`) — covariance inflation on a large residual.
  * `:adaptive_cutoff` (`3.0`) — residual multiple of `max_error` that
    triggers forgetting.
  * `:min_samples` (`100`) — samples before forgetting is enabled.
  * `:drift_significance_threshold` (`2.0`) — SNR gate before drift is
    applied to conversions.
  * `:max_error_scale` (`0.5`) — scale from half-RTT to measurement
    standard deviation.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) when is_list(opts) do
    process_std_dev = float_opt(opts, :process_std_dev, 0.0)
    drift_process_std_dev = float_opt(opts, :drift_process_std_dev, 1.0e-11)
    forget_factor = float_opt(opts, :forget_factor, 2.0)
    drift_threshold = float_opt(opts, :drift_significance_threshold, 2.0)

    %__MODULE__{
      process_variance: process_std_dev * process_std_dev,
      drift_process_variance: drift_process_std_dev * drift_process_std_dev,
      forget_variance_factor: forget_factor * forget_factor,
      adaptive_cutoff: float_opt(opts, :adaptive_cutoff, 3.0),
      max_error_scale: float_opt(opts, :max_error_scale, 0.5),
      min_samples: Keyword.get(opts, :min_samples, 100),
      drift_significance_threshold_squared: drift_threshold * drift_threshold
    }
  end

  @doc """
  Fold one `client/time` -> `server/time` exchange into the filter.

  All four timestamps are microseconds: `client_transmitted_us` (T1)
  and `client_received_us` (T4) in the caller's local basis,
  `server_received_us` (T2) and `server_transmitted_us` (T3) as echoed
  by the server.
  """
  @spec update(t(), integer(), integer(), integer(), integer()) :: t()
  def update(
        %__MODULE__{} = filter,
        client_transmitted_us,
        server_received_us,
        server_transmitted_us,
        client_received_us
      ) do
    measurement =
      (server_received_us - client_transmitted_us + (server_transmitted_us - client_received_us)) /
        2

    max_error =
      (client_received_us - client_transmitted_us - (server_transmitted_us - server_received_us)) /
        2

    update_measurement(filter, round(measurement), round(max_error), client_received_us)
  end

  @doc """
  Fold a pre-computed measurement into the filter.

  `measurement` is the estimated server-minus-local offset in µs,
  `max_error` half the round-trip delay in µs, and `time_added` the
  local timestamp the measurement belongs to. Measurements whose
  `time_added` does not strictly advance are ignored.
  """
  @spec update_measurement(t(), integer(), integer(), integer()) :: t()
  def update_measurement(%__MODULE__{} = filter, measurement, max_error, time_added)
      when is_integer(measurement) and is_integer(max_error) and is_integer(time_added) do
    if stale?(filter, time_added) do
      filter
    else
      do_update(filter, measurement, max_error, time_added)
    end
  end

  @doc """
  Map a local timestamp (µs) into the server's clock domain.

  Used to stamp outgoing audio frames. Safe before convergence — it
  degrades to the identity — but per the source@v1 spec a source must
  not report `available: true` until `converged?/1`.
  """
  @spec server_time(t(), integer()) :: integer()
  def server_time(%__MODULE__{last_update: nil}, local_us), do: local_us

  def server_time(%__MODULE__{last_update: last_update} = filter, local_us) do
    dt = (local_us - last_update) * 1.0
    local_us + round(filter.offset + effective_drift(filter) * dt)
  end

  @doc """
  Map a server timestamp (µs) back into the caller's local clock domain.
  """
  @spec client_time(t(), integer()) :: integer()
  def client_time(%__MODULE__{last_update: nil}, server_us), do: server_us

  def client_time(%__MODULE__{last_update: last_update} = filter, server_us) do
    drift = effective_drift(filter)
    round((server_us - filter.offset + drift * last_update) / (1.0 + drift))
  end

  @doc """
  True once the estimate is usable: at least two measurements folded in
  and a bounded offset covariance (upstream `is_synchronized`).
  """
  @spec converged?(t()) :: boolean()
  def converged?(%__MODULE__{count: count, offset_covariance: covariance}) do
    count >= 2 and is_float(covariance)
  end

  @doc """
  Standard deviation of the offset estimate in µs, or `:infinity`
  before the first measurement.
  """
  @spec error(t()) :: non_neg_integer() | :infinity
  def error(%__MODULE__{offset_covariance: nil}), do: :infinity

  def error(%__MODULE__{offset_covariance: covariance}) do
    round(:math.sqrt(max(covariance, 0.0)))
  end

  @doc "Current filtered offset estimate in µs."
  @spec offset(t()) :: float()
  def offset(%__MODULE__{offset: offset}), do: offset

  @doc "Number of measurements folded in, saturating at `:min_samples`."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{count: count}), do: count

  @doc """
  Clear all estimates, keeping the tuning. Call on reconnect: the local
  clock basis and the server's clock may both have moved.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = filter) do
    %{
      filter
      | count: 0,
        last_update: nil,
        offset: 0.0,
        drift: 0.0,
        offset_covariance: nil,
        offset_drift_covariance: 0.0,
        drift_covariance: 0.0,
        use_drift: false
    }
  end

  ## Internals

  defp stale?(%__MODULE__{last_update: nil}, _time_added), do: false
  defp stale?(%__MODULE__{last_update: last_update}, time_added), do: time_added <= last_update

  defp do_update(%__MODULE__{count: 0} = filter, measurement, max_error, time_added) do
    %{
      filter
      | count: 1,
        last_update: time_added,
        offset: measurement * 1.0,
        offset_covariance: measurement_variance(filter, max_error),
        drift: 0.0,
        use_drift: false
    }
  end

  defp do_update(
         %__MODULE__{count: 1, offset_covariance: prior_covariance} = filter,
         measurement,
         max_error,
         time_added
       ) do
    dt = (time_added - filter.last_update) * 1.0
    variance = measurement_variance(filter, max_error)

    # Second sample: seed drift by finite difference, and its variance
    # by propagating both offset uncertainties over dt.
    %{
      filter
      | count: 2,
        last_update: time_added,
        drift: (measurement - filter.offset) / dt,
        offset: measurement * 1.0,
        drift_covariance: (prior_covariance + variance) / (dt * dt),
        offset_covariance: variance,
        use_drift: false
    }
  end

  defp do_update(%__MODULE__{} = filter, measurement, max_error, time_added) do
    dt = (time_added - filter.last_update) * 1.0
    dt_squared = dt * dt
    variance = measurement_variance(filter, max_error)

    # Predict: x = F * x, P = F * P * F' + Q, with F = [1, dt; 0, 1].
    predicted_offset = filter.offset + filter.drift * dt

    drift_covariance = filter.drift_covariance + dt * filter.drift_process_variance
    offset_drift_covariance = filter.offset_drift_covariance + filter.drift_covariance * dt

    offset_covariance =
      filter.offset_covariance + 2 * filter.offset_drift_covariance * dt +
        filter.drift_covariance * dt_squared + dt * filter.process_variance

    residual = measurement - predicted_offset

    covariances = {drift_covariance, offset_drift_covariance, offset_covariance}

    {count, {drift_covariance, offset_drift_covariance, offset_covariance}} =
      forget(filter, residual, max_error, covariances)

    # Denominator floored so a zero-error loopback peer cannot divide by zero.
    uncertainty = 1.0 / max(offset_covariance + variance, 1.0e-9)
    offset_gain = offset_covariance * uncertainty
    drift_gain = offset_drift_covariance * uncertainty

    drift = filter.drift + drift_gain * residual
    new_drift_covariance = drift_covariance - drift_gain * offset_drift_covariance

    %{
      filter
      | count: count,
        last_update: time_added,
        offset: predicted_offset + offset_gain * residual,
        drift: drift,
        drift_covariance: new_drift_covariance,
        offset_drift_covariance: offset_drift_covariance - drift_gain * offset_covariance,
        offset_covariance: offset_covariance - offset_gain * offset_covariance,
        use_drift:
          drift * drift > filter.drift_significance_threshold_squared * new_drift_covariance
    }
  end

  defp forget(
         filter,
         residual,
         max_error,
         {drift_cov, offset_drift_cov, offset_cov} = covariances
       ) do
    cond do
      filter.count < filter.min_samples ->
        {filter.count + 1, covariances}

      abs(residual) > max_error * filter.adaptive_cutoff ->
        factor = filter.forget_variance_factor
        {filter.count, {drift_cov * factor, offset_drift_cov * factor, offset_cov * factor}}

      true ->
        {filter.count, covariances}
    end
  end

  defp measurement_variance(%__MODULE__{max_error_scale: scale}, max_error) do
    std_dev = max_error * scale
    std_dev * std_dev
  end

  defp effective_drift(%__MODULE__{use_drift: true, drift: drift}), do: drift
  defp effective_drift(%__MODULE__{}), do: 0.0

  defp float_opt(opts, key, default) do
    opts |> Keyword.get(key, default) |> then(&(&1 * 1.0))
  end
end
