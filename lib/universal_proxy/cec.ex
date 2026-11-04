defmodule UniversalProxy.Cec do
  @moduledoc """
  Public API for HDMI-CEC control of whatever sits on the far end of a Pi's
  HDMI link: in practice the AV receiver that carries the HDMI audio output,
  or the TV when there is no receiver.

  Each `/dev/cecN` is run by a `Circuits.CEC.Adapter` (native, no
  `cec-ctl`), which claims a Playback logical address and answers the bus
  as a playback device. `UniversalProxy.Cec.Server` starts the adapters,
  pairs each with its HDMI ALSA card and keeps the `receiver` state current.
  Adapters are identified by their device path (`"/dev/cec0"`);
  `list_adapters/0` shows which ALSA card (hence which Sendspin output) each
  one belongs to.

  Commands go to the receiver (logical address 5 by default, the
  `:receiver_la` config) and fall back to the TV (0) when nothing answers
  there. `:to` overrides the destination (`:tv`, `:audio_system`,
  `:broadcast`, a logical address); without it, a per-call `:receiver_la`
  does the same. The receiver record in `list_adapters/0` only reflects
  what the current receiver itself reported.

  When the subsystem is off (host, `enabled: false`, or not started yet)
  every function degrades to a harmless default, `{:error,
  :cec_unavailable}` for commands: the project's `catch :exit` idiom. A
  command that doesn't return in time is `{:error, :timeout}` instead, so a
  wedged adapter doesn't look like a disabled subsystem.

  Typical IEx session on a Pi:

      UniversalProxy.Cec.list_adapters()
      UniversalProxy.Cec.power_status("/dev/cec0")   #=> {:ok, :standby}
      UniversalProxy.Cec.one_touch_play("/dev/cec0") #=> :ok  (receiver wakes, selects our input)
      UniversalProxy.Cec.volume_up("/dev/cec0")
      UniversalProxy.Cec.standby("/dev/cec0")
  """

  alias Circuits.CEC.Adapter
  alias UniversalProxy.Cec.{Server, Supervisor}

  @type dev :: String.t()
  @type power :: Server.power()
  @type error :: :cec_unavailable | :no_such_adapter | :timeout | Adapter.error()
  @typedoc "The receiver's volume (0..100, nil if it won't say) and mute state."
  @type audio_status :: %{volume: 0..100 | nil, muted: boolean()}
  @typedoc "Why `set_volume/3` stopped short; a status is the last readback."
  @type step_error ::
          :unknown_volume | {:no_progress, audio_status()} | {:press_limit, audio_status()}

  @ui_keys %{power_on: :power_on_function, power_off: :power_off_function}

  # Consecutive presses that bring the volume no closer before giving up.
  @stall_presses 2
  # Presses allowed on top of the distance to the target, and the cap.
  @press_slack 5
  @press_cap 100 + @press_slack

  @doc """
  PubSub topic (on `UniversalProxy.PubSub`) carrying `{:cec_event, dev,
  event}` for every adapter event and `{:cec_adapters, adapters}` (the
  `list_adapters/0` result) whenever a record changes.
  """
  @spec topic() :: String.t()
  defdelegate topic(), to: Server

  @doc "All CEC adapters with what is known about them and their receiver."
  @spec list_adapters() :: [Server.adapter()]
  def list_adapters do
    Server.list_adapters()
  catch
    :exit, _ -> []
  end

  @doc "One adapter by device path."
  @spec get_adapter(dev()) :: {:ok, Server.adapter()} | :error
  def get_adapter(dev) when is_binary(dev) do
    Server.get_adapter(dev)
  catch
    :exit, _ -> :error
  end

  @doc """
  The adapter's own view (`Circuits.CEC.Adapter.info/1`): caps, connector,
  addresses, claim and follower status, receiver and counters.
  """
  @spec info(dev()) :: {:ok, map()} | {:error, error()}
  def info(dev), do: with_adapter(dev, &{:ok, Adapter.info(&1)})

  @doc """
  Whether a stream starting on this audio output wakes its receiver (One
  Touch Play). The output's own `cec_auto_wake` setting wins; an output
  without one follows `default`, the `auto_wake` env key (`true` unless
  configured otherwise).
  """
  @spec auto_wake?(map(), boolean()) :: boolean()
  def auto_wake?(output, default \\ default_auto_wake())
  def auto_wake?(%{cec_auto_wake: value}, _default) when is_boolean(value), do: value
  def auto_wake?(_output, default), do: default

  defp default_auto_wake do
    :universal_proxy
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:auto_wake, true)
  end

  @doc "True when the subsystem is running and this build has the CEC helper."
  @spec available?() :: boolean()
  def available? do
    Process.whereis(Server) != nil and Circuits.CEC.supported?()
  end

  @doc """
  One Touch Play: `<Image View On>` to the TV, then broadcast `<Active
  Source>` with our physical address. Wakes a receiver or TV in standby and
  switches it to the Pi's HDMI input. Without a physical address (a sink
  that dropped hotplug in standby) the adapter sends `<Image View On>` from
  Unregistered and waits for the address before `<Active Source>`.

  Options: `:wait_ms` (default 10 s), `:system_audio_mode` (default: the
  config's `system_audio_mode`).
  """
  @spec one_touch_play(dev() | Server.adapter(), keyword()) :: :ok | {:error, error()}
  def one_touch_play(dev_or_adapter, opts \\ [])

  def one_touch_play(%{dev: dev}, opts), do: one_touch_play(dev, opts)

  def one_touch_play(dev, opts) when is_binary(dev) do
    otp_opts = Keyword.take(opts, [:wait_ms, :system_audio_mode, :call_timeout])
    with_adapter(dev, &Adapter.one_touch_play(&1, otp_opts))
  end

  @doc "Put the receiver into standby (directed, not the broadcast that would also hit the TV)."
  @spec standby(dev(), keyword()) :: :ok | {:error, error()}
  def standby(dev, opts \\ []) do
    to = to(opts)
    version = receiver_version(dev)

    with :ok <- with_adapter(dev, &Adapter.standby(&1, to, call_opts(opts))) do
      if version, do: Server.note_receiver(dev, to, version, %{power: :to_standby})
      :ok
    end
  end

  @doc """
  Ask the receiver for its power state. The reply is recorded on the
  adapter when it comes from the receiver.
  """
  @spec power_status(dev(), keyword()) :: {:ok, power()} | {:error, error()}
  def power_status(dev, opts \\ []) do
    with {:ok, power} <-
           with_adapter(dev, &Adapter.give_power_status(&1, to(opts), call_opts(opts))) do
      {:ok, Server.power(power)}
    end
  end

  @doc "Ask the receiver for its volume (0..100, or nil if it won't say) and mute state."
  @spec audio_status(dev(), keyword()) :: {:ok, audio_status()} | {:error, error()}
  def audio_status(dev, opts \\ []) do
    with {:ok, %{volume: volume, muted: muted}} <-
           with_adapter(dev, &Adapter.give_audio_status(&1, to(opts), call_opts(opts))) do
      {:ok, Server.audio_status(muted, volume)}
    end
  end

  @doc """
  Step the receiver's volume to `target` (0..100) with volume-up/down key
  presses, reading the status back after each one: back-to-back presses
  without a readback in between get dropped. Runs in the caller's
  process, one adapter call at a time, so a long walk holds neither
  `Cec.Server` nor the adapter between calls.

  Stepping only: receivers commonly Feature-Abort `<Set Audio Volume
  Level>`, and one that accepts it sends no reply, so probing for it
  costs a full reply timeout.

  `{:ok, status}` once the receiver reports `target`, or with the first
  readback past it when the receiver's step is coarser than one (the
  caller compares). Stops with `{:error, {:no_progress, status}}` after
  #{@stall_presses} presses in a row bring it no closer, and with
  `{:error, {:press_limit, status}}` after `:max_presses` (default: the
  distance plus #{@press_slack}); `status` is the last readback.
  `{:error, :unknown_volume}` when the receiver won't report a volume.
  Takes the `user_control/3` and `audio_status/2` options.
  """
  @spec set_volume(dev(), 0..100, keyword()) ::
          {:ok, audio_status()} | {:error, error() | step_error()}
  def set_volume(dev, target, opts \\ []) when is_integer(target) and target in 0..100 do
    with {:ok, %{volume: volume} = status} <- known_volume(audio_status(dev, opts)) do
      default = min(abs(target - volume) + @press_slack, @press_cap)
      presses = Keyword.get(opts, :max_presses, default)
      step_volume(dev, target, status, abs(target - volume), presses, 0, opts)
    end
  end

  @doc """
  Bring the receiver's mute to `wanted`. Mute is a toggle key, so it is
  pressed only while the reported state differs, each press read back,
  at most twice (one retry for a dropped press). Returns the last status
  read; the caller compares its `muted` with `wanted`.
  """
  @spec set_muted(dev(), boolean(), keyword()) :: {:ok, audio_status()} | {:error, error()}
  def set_muted(dev, wanted, opts \\ []) when is_boolean(wanted) do
    with {:ok, status} <- audio_status(dev, opts) do
      toggle_mute(dev, wanted, status, 2, opts)
    end
  end

  @doc "One volume-up key press on the receiver."
  @spec volume_up(dev(), keyword()) :: :ok | {:error, error()}
  def volume_up(dev, opts \\ []), do: user_control(dev, :volume_up, opts)

  @doc "One volume-down key press on the receiver."
  @spec volume_down(dev(), keyword()) :: :ok | {:error, error()}
  def volume_down(dev, opts \\ []), do: user_control(dev, :volume_down, opts)

  @doc "Toggle the receiver's mute."
  @spec mute(dev(), keyword()) :: :ok | {:error, error()}
  def mute(dev, opts \\ []), do: user_control(dev, :mute, opts)

  @doc """
  Press and release one remote-control key on the receiver: `:volume_up`,
  `:volume_down`, `:mute`, `:power_on`, `:power_off`, or any
  `Circuits.CEC.Message.ui_command/1` name.
  """
  @spec user_control(dev(), atom(), keyword()) :: :ok | {:error, error()}
  def user_control(dev, key, opts \\ []) when is_atom(key) do
    key = Map.get(@ui_keys, key, key)
    with_adapter(dev, &Adapter.user_control(&1, to(opts), key, call_opts(opts)))
  end

  # ── private ───────────────────────────────────────────────────────────

  defp step_volume(_dev, target, %{volume: target} = status, _best, _left, _stalled, _opts),
    do: {:ok, status}

  defp step_volume(_dev, _target, status, _best, _left, @stall_presses, _opts),
    do: {:error, {:no_progress, status}}

  defp step_volume(_dev, _target, status, _best, 0, _stalled, _opts),
    do: {:error, {:press_limit, status}}

  defp step_volume(dev, target, %{volume: volume}, best, left, stalled, opts) do
    key = if target > volume, do: :volume_up, else: :volume_down

    with :ok <- user_control(dev, key, opts),
         {:ok, %{volume: now} = status} <- known_volume(audio_status(dev, opts)) do
      distance = abs(target - now)

      cond do
        # Overshot: the next press would only cross back.
        now != target and target > volume != target > now ->
          {:ok, status}

        distance < best ->
          step_volume(dev, target, status, distance, left - 1, 0, opts)

        true ->
          step_volume(dev, target, status, best, left - 1, stalled + 1, opts)
      end
    end
  end

  defp known_volume({:ok, %{volume: nil}}), do: {:error, :unknown_volume}
  defp known_volume(result), do: result

  defp toggle_mute(_dev, wanted, %{muted: wanted} = status, _presses, _opts), do: {:ok, status}
  defp toggle_mute(_dev, _wanted, status, 0, _opts), do: {:ok, status}

  defp toggle_mute(dev, wanted, _status, presses, opts) do
    with :ok <- mute(dev, opts),
         {:ok, status} <- audio_status(dev, opts) do
      toggle_mute(dev, wanted, status, presses - 1, opts)
    end
  end

  defp receiver_version(dev) do
    Server.receiver_version(dev)
  catch
    :exit, _ -> nil
  end

  defp to(opts) do
    case Keyword.fetch(opts, :to) do
      {:ok, to} -> to
      :error -> Keyword.get(opts, :receiver_la, :receiver)
    end
  end

  defp call_opts(opts), do: Keyword.take(opts, [:call_timeout, :timeout])

  defp with_adapter(dev, fun) when is_binary(dev) do
    case lookup(dev) do
      {:ok, pid} -> call_adapter(fn -> fun.(pid) end)
      {:error, _} = error -> error
    end
  end

  # Registry.lookup/2 raises (not exits) when the registry isn't running.
  defp lookup(dev) do
    case Registry.lookup(Supervisor.registry(), dev) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :no_such_adapter}
    end
  rescue
    ArgumentError -> {:error, :cec_unavailable}
  end

  # Public (`@doc false`) so the timeout conversion is unit-testable. Only
  # call-shaped exits are caught: a timeout is a wedged adapter, anything
  # else (not running, stopped mid-call) is the subsystem being off.
  @doc false
  @spec call_adapter((-> result)) :: result | {:error, :timeout | :cec_unavailable}
        when result: term()
  def call_adapter(fun) do
    fun.()
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, :timeout}
    :exit, {_reason, {GenServer, :call, _}} -> {:error, :cec_unavailable}
  end
end
