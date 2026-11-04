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
  there. `:to` overrides the destination (`:tv`, `:audio_system`, a logical
  address).

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

  @ui_keys %{power_on: :power_on_function, power_off: :power_off_function}

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
    with :ok <- with_adapter(dev, &Adapter.standby(&1, to(opts), call_opts(opts))) do
      Server.note_receiver(dev, %{power: :to_standby})
      :ok
    end
  end

  @doc "Ask the receiver for its power state; also recorded on the adapter."
  @spec power_status(dev(), keyword()) :: {:ok, power()} | {:error, error()}
  def power_status(dev, opts \\ []) do
    with {:ok, power} <-
           with_adapter(dev, &Adapter.give_power_status(&1, to(opts), call_opts(opts))) do
      power = Server.power(power)
      Server.note_receiver(dev, %{power: power})
      {:ok, power}
    end
  end

  @doc "Ask the receiver for its volume (0..100, or nil if it won't say) and mute state."
  @spec audio_status(dev(), keyword()) ::
          {:ok, %{volume: 0..100 | nil, muted: boolean()}} | {:error, error()}
  def audio_status(dev, opts \\ []) do
    with {:ok, %{volume: volume, muted: muted}} <-
           with_adapter(dev, &Adapter.give_audio_status(&1, to(opts), call_opts(opts))) do
      status = Server.audio_status(muted, volume)
      Server.note_receiver(dev, status)
      {:ok, status}
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

  defp to(opts), do: Keyword.get(opts, :to, :receiver)
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
