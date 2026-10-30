defmodule UniversalProxy.Cec do
  @moduledoc """
  Public API for HDMI-CEC control of whatever sits on the far end of a Pi's
  HDMI link — in practice the AV receiver that carries the HDMI audio output.

  Backed by `cec-ctl` one-shots (see `UniversalProxy.Cec.Ctl`) plus a
  continuous `cec-ctl -m` monitor per adapter (`UniversalProxy.Cec.Monitor`)
  that keeps `receiver` state current. Adapters are identified by their
  device path (`"/dev/cec0"`); `list_adapters/0` shows which ALSA card
  (hence which Sendspin output) each one belongs to.

  Every function degrades to a harmless default when the subsystem is off
  (host, `enabled: false`, or not started yet) — the project's `catch :exit`
  idiom. Commands run in the caller's process; the Server is only consulted
  for the adapter record.

  Typical IEx session on a Pi:

      UniversalProxy.Cec.list_adapters()
      UniversalProxy.Cec.power_status("/dev/cec0")   #=> {:ok, :standby}
      UniversalProxy.Cec.one_touch_play("/dev/cec0") #=> :ok  (receiver wakes, selects our input)
      UniversalProxy.Cec.volume_up("/dev/cec0")
      UniversalProxy.Cec.standby("/dev/cec0")
  """

  require Logger

  alias UniversalProxy.Cec.{Ctl, Parser, Server}

  @type dev :: String.t()
  @type power :: :on | :standby | :to_on | :to_standby | :unknown

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

  @doc "True when the subsystem is running and cec-ctl exists on this image."
  @spec available?() :: boolean()
  def available? do
    Process.whereis(Server) != nil and Ctl.available?()
  end

  @doc """
  One Touch Play: Image View On to the TV address, then broadcast Active
  Source with our physical address. Wakes a receiver or TV in standby and
  switches it to the Pi's HDMI input. Active Source is skipped while the
  link reports no valid physical address (cable unplugged / EDID not read).
  """
  @spec one_touch_play(dev() | Server.adapter(), keyword()) :: :ok | {:error, term()}
  def one_touch_play(dev_or_adapter, opts \\ []) do
    with {:ok, adapter, ctl, _la} <- resolve(dev_or_adapter, opts),
         {:ok, _} <- ctl.run(Ctl.image_view_on_args(adapter.dev), []) do
      if Parser.valid_phys_addr?(adapter.phys_addr) do
        case ctl.run(Ctl.active_source_args(adapter.dev, adapter.phys_addr), []) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:active_source, reason}}
        end
      else
        Logger.info("CEC: no physical address on #{adapter.dev}; sent Image View On only")
        :ok
      end
    end
  end

  @doc "Put the receiver into standby (directed, not the broadcast that would also hit the TV)."
  @spec standby(dev(), keyword()) :: :ok | {:error, term()}
  def standby(dev, opts \\ []) do
    with {:ok, adapter, ctl, la} <- resolve(dev, opts),
         {:ok, _} <- ctl.run(Ctl.standby_args(adapter.dev, la), []) do
      Server.note_receiver(adapter.dev, %{power: :to_standby})
      :ok
    end
  end

  @doc "Ask the receiver for its power state; also recorded on the adapter."
  @spec power_status(dev(), keyword()) :: {:ok, power()} | {:error, term()}
  def power_status(dev, opts \\ []) do
    with {:ok, adapter, ctl, la} <- resolve(dev, opts),
         {:ok, out} <- ctl.run(Ctl.give_power_status_args(adapter.dev, la), []),
         %{opcode: "REPORT_POWER_STATUS"} = reply <- Parser.reply(out) || {:error, :no_reply} do
      power = Parser.power_state(reply)
      Server.note_receiver(adapter.dev, %{power: power})
      {:ok, power}
    else
      {:error, _} = err -> err
      _other -> {:error, :unexpected_reply}
    end
  end

  @doc "Ask the receiver for its volume (0..100, or nil if it won't say) and mute state."
  @spec audio_status(dev(), keyword()) ::
          {:ok, %{volume: 0..100 | nil, muted: boolean()}} | {:error, term()}
  def audio_status(dev, opts \\ []) do
    with {:ok, adapter, ctl, la} <- resolve(dev, opts),
         {:ok, out} <- ctl.run(Ctl.give_audio_status_args(adapter.dev, la), []),
         %{opcode: "REPORT_AUDIO_STATUS"} = reply <- Parser.reply(out) || {:error, :no_reply} do
      status = Parser.audio_status(reply)
      Server.note_receiver(adapter.dev, status)
      {:ok, status}
    else
      {:error, _} = err -> err
      _other -> {:error, :unexpected_reply}
    end
  end

  @doc "One volume-up key press on the receiver."
  @spec volume_up(dev(), keyword()) :: :ok | {:error, term()}
  def volume_up(dev, opts \\ []), do: user_control(dev, :volume_up, opts)

  @doc "One volume-down key press on the receiver."
  @spec volume_down(dev(), keyword()) :: :ok | {:error, term()}
  def volume_down(dev, opts \\ []), do: user_control(dev, :volume_down, opts)

  @doc "Toggle the receiver's mute."
  @spec mute(dev(), keyword()) :: :ok | {:error, term()}
  def mute(dev, opts \\ []), do: user_control(dev, :mute, opts)

  @doc "Send one remote-control key (`:volume_up | :volume_down | :mute | :power_on | :power_off`)."
  @spec user_control(dev(), atom(), keyword()) :: :ok | {:error, term()}
  def user_control(dev, key, opts \\ []) do
    with {:ok, adapter, ctl, la} <- resolve(dev, opts),
         {:ok, _} <- ctl.run(Ctl.user_control_args(adapter.dev, la, key), []) do
      :ok
    end
  end

  # ── private ───────────────────────────────────────────────────────────

  # Server.handle_info passes the adapter it already holds (plus its ctl
  # module) so the auto-wake task never calls back into the Server.
  defp resolve(%{dev: _} = adapter, opts) do
    {:ok, adapter, Keyword.get(opts, :ctl, ctl_module()), Keyword.get(opts, :receiver_la, 5)}
  end

  defp resolve(dev, opts) when is_binary(dev) do
    case Server.get_adapter(dev) do
      {:ok, adapter} ->
        la = Keyword.get_lazy(opts, :receiver_la, fn -> Server.receiver_la() end)
        {:ok, adapter, Keyword.get(opts, :ctl, ctl_module()), la}

      :error ->
        {:error, :no_such_adapter}
    end
  catch
    :exit, _ -> {:error, :cec_unavailable}
  end

  defp ctl_module do
    :universal_proxy
    |> Application.get_env(UniversalProxy.Cec, [])
    |> Keyword.get(:ctl_module, Ctl)
  end
end
