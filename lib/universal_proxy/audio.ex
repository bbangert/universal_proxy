defmodule UniversalProxy.Audio do
  @moduledoc """
  Public API for the audio (Sendspin) subsystem.

  Thin boundary over `UniversalProxy.Audio.Server` and
  `UniversalProxy.Audio.Store`. The Server holds the live, merged view
  of enumerated outputs plus their persisted configuration; the Store
  owns the DETS table that survives reboots. Callers (LiveView,
  Phase 3's `Audio.Player`) should reach in via this module only.

  Outputs are identified by a `{slot_sub, vendor_id, product_id}`
  tuple. For built-in SoC cards on v1 hardware that's
  `{card_name, nil, nil}` (e.g. `{"bcm2835 Headphones", nil, nil}`).
  """

  alias UniversalProxy.Audio.{PairingToken, Player, Server, Store}

  @typedoc """
  Composite identifier for an audio output:
  `{slot_sub, vendor_id, product_id}`.
  """
  @type key :: Store.output_key()

  @doc """
  List all currently-present audio outputs as merged maps (enumerate
  info + persisted config), sorted by `friendly_name`.
  """
  @spec list_outputs() :: [map()]
  def list_outputs, do: Server.list_outputs()

  @doc """
  Look up a single output. Returns `{:ok, merged_map}` if present,
  `:error` otherwise.
  """
  @spec get_output(key()) :: {:ok, map()} | :error
  def get_output({_, _, _} = key), do: Server.get_output(key)

  @doc """
  Update one or more configuration fields. Accepted keys:
  `:friendly_name`, `:volume`, `:muted`, `:cec_auto_wake` and
  `:cec_volume` (a boolean, or `nil` to fall back to the CEC default),
  `:cec_volume_max` (1..100, or `nil` for no cap on the volume sent to
  the receiver). Anything else is silently dropped. Returns `{:error,
  :not_found}` if the output isn't currently present, or `{:error,
  reason}` if DETS rejects the write.
  """
  @spec update_config(key(), map()) :: :ok | {:error, :not_found | term()}
  def update_config({_, _, _} = key, params) when is_map(params) do
    Server.update_config(key, params)
  end

  @doc """
  `update_config/2`, but `{:ok, player}` names the player process a volume
  or mute change was handed to; it reports that value back as a
  `volume`/`mute` event carrying `player: pid` (`nil` when no player is
  running). `{:error, :unavailable}` while the audio subsystem is down.
  """
  @spec update_config_forwarded(key(), map()) ::
          {:ok, pid() | nil} | {:error, :not_found | :unavailable | term()}
  def update_config_forwarded({_, _, _} = key, params) when is_map(params) do
    Server.update_config_forwarded(key, params)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Hand an output's volume and mute to an outboard stage (`true`: the
  player plays at unity gain but keeps tracking and reporting both) or
  take them back (`false`). Not persisted: kept until the output goes
  away or the audio subsystem restarts, and applied to players respawned
  meanwhile. `{:error, :not_found}` if the output isn't present,
  `{:error, :unavailable}` while the audio subsystem is down.
  """
  @spec set_volume_external(key(), boolean()) :: :ok | {:error, :not_found | :unavailable}
  def set_volume_external({_, _, _} = key, external?) when is_boolean(external?) do
    Server.set_volume_external(key, external?)
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Enable or disable an output, persisted in DETS. Returns
  `{:error, :not_found}` if the output isn't currently present, or
  `{:error, reason}` if DETS rejects the write.
  """
  @spec set_enabled(key(), boolean()) :: :ok | {:error, :not_found | term()}
  def set_enabled({_, _, _} = key, enabled?) when is_boolean(enabled?) do
    Server.set_enabled(key, enabled?)
  end

  @doc """
  Send a transport command (`:play`, `:pause`, `:stop`, `:next`,
  `:previous`) through the controller role of an output's player. Only
  the output carrying the display roles (`list_outputs/0` shows
  `display_roles: true`) has one. The outcome arrives as a
  `controller_result` event on `"sendspin:display"`.

  `{:error, :not_found}` when the output has no running player,
  `{:error, :display_roles_disabled}` when its player has no display
  roles, `{:error, :unavailable}` while the audio subsystem or the player
  is down or wedged (the `catch :exit` idiom: a timeout reads the same).
  """
  @spec controller(key(), Player.controller_command()) ::
          :ok | {:error, :not_found | :display_roles_disabled | :unavailable}
  def controller({_, _, _} = key, command) do
    with_player(key, &Player.controller(&1, command))
  end

  @doc """
  Turn an output player's visualizer frames (`viz_topic/1`) on or off.
  Same results as `controller/2`.
  """
  @spec viz_enable(key(), boolean()) ::
          :ok | {:error, :not_found | :display_roles_disabled | :unavailable}
  def viz_enable({_, _, _} = key, enabled?) when is_boolean(enabled?) do
    with_player(key, &Player.viz_enable(&1, enabled?))
  end

  @doc """
  The latest display state of an output's player as `{seq, snapshot}`
  (see `UniversalProxy.Audio.Player.display_snapshot/1`); `{0, %{}}` when
  it has no running player or the audio subsystem is down.
  """
  @spec display_snapshot(key()) :: {non_neg_integer(), map()}
  def display_snapshot({_, _, _} = key) do
    case with_player(key, &Player.display_snapshot/1) do
      {seq, snapshot} when is_integer(seq) and is_map(snapshot) -> {seq, snapshot}
      {:error, _} -> {0, %{}}
    end
  end

  @doc """
  The PubSub topic an output's visualizer frames are broadcast on, from
  its `client_id` (as in `list_outputs/0`).
  """
  @spec viz_topic(String.t()) :: String.t()
  defdelegate viz_topic(client_id), to: Player

  # The pid is looked up per call, never cached: players respawn.
  defp with_player(key, fun) do
    case Server.player_pid(key) do
      {:ok, pid} -> fun.(pid)
      :error -> {:error, :not_found}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Read an output's Sendspin pairing token (the `"SP:..."` string a
  Sendspin server such as Music Assistant takes to pair with the output).

  Read from the player's state dir on every call and never cached or
  broadcast: it is a long-lived pairing secret. `{:error, :not_ready}`
  until the output's player has started once; `{:error, :unavailable}`
  when the output isn't present, the audio subsystem is down, or the
  file is unreadable or malformed.
  """
  @spec pairing_token(key()) :: {:ok, String.t()} | {:error, :not_ready | :unavailable}
  def pairing_token({_, _, _} = key) do
    case Server.state_dir(key) do
      {:ok, dir} -> PairingToken.read(dir)
      :error -> {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
