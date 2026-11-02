defmodule UniversalProxy.TuyaBeaconMesh.Control do
  @moduledoc """
  Friendly DP translation and unicast request builders for Beacon v2 bulbs.

  Pure: no I/O. Callers supply keys, node id and a sequence number; this
  module returns `{frame, send_ms, window_ms, expect}` ready for a radio
  to advertise.

  Hardware-proven conventions (garden Beacon v2 bulbs, 2026-10-25):

    * source address is always `0x8001` — the cloud `sourceId` is ignored
      by bulbs (yet still advances their SN trackers);
    * unicast XXTEA key = bulb `localKey`, XOR mask = mesh `beaconKey`;
    * group frames to `FFgg` use `(beaconKey, beaconKey)` — bulbs never
      learn a distinct groupKey;
    * advertise for at least 3_000 ms (builders' nominal times are shorter;
      the scan duty cycle needs the longer window).

  Sequence numbers are the caller's problem: every bulb tracks the phone's
  SN across all destinations, accepts only SNs ahead of the highest it has
  seen, and silently drops the rest. Keep one monotonic counter for the
  whole mesh; never reuse or go backwards.
  """

  alias UniversalProxy.TuyaBeaconMesh.{Dp, P2}

  @phone_addr 0x8001
  @min_send_ms 3_000

  @modes %{white: 0, colour: 1, scene: 2, music: 3}

  @type key :: binary() | String.t()
  @type request :: {binary(), pos_integer(), non_neg_integer(), atom()}

  @doc "Phone source address the bulbs accept (`0x8001`)."
  @spec phone_addr() :: 0x8001
  def phone_addr, do: @phone_addr

  @doc "Minimum on-air time that measurably improves reception."
  @spec min_send_ms() :: 3_000
  def min_send_ms, do: @min_send_ms

  @doc """
  Turns friendly keys into DP tuples.

  Supported: `on:` boolean, `brightness:` 10..1000, `temp:` 0..1000,
  `colour: {h, s, v}` (h 0..359, s/v 0..100), `mode:` `:white`/`:colour`/
  `:scene`/`:music` or a 0..255 enum index.

  A raw `t:UniversalProxy.TuyaBeaconMesh.Dp.dp/0` tuple (`{id, type,
  value}`) is accepted too, for DPs without a friendly key, and passes
  through once `Dp.encode/1` accepts it on its own.

  Total: anything else is `{:error, {:bad_dp, shape}}`, where `shape` is
  the friendly key, a raw DP's `{id, type}`, or the kind of term
  (`Dp.shape/1`), never a value. Input that is not a proper list or a map
  is `{:error, :bad_dps}`, and an empty one `{:error, :no_dps}`.
  """
  @spec friendly_dps(term()) :: {:ok, [Dp.dp()]} | {:error, term()}
  def friendly_dps(dps) when is_map(dps), do: friendly_dps(Map.to_list(dps))

  def friendly_dps(dps) when is_list(dps) do
    if proper_list?(dps), do: translate(dps), else: {:error, :bad_dps}
  end

  def friendly_dps(_dps), do: {:error, :bad_dps}

  defp translate(dps) do
    dps
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case friendly_dp(entry) do
        {:ok, dp} -> {:cont, {:ok, [dp | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, []} -> {:error, :no_dps}
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  defp friendly_dp({:on, on}) when is_boolean(on), do: {:ok, {1, :bool, on}}

  defp friendly_dp({:brightness, v}) when is_integer(v) and v in 10..1000,
    do: {:ok, {3, :value, v}}

  defp friendly_dp({:temp, v}) when is_integer(v) and v in 0..1000, do: {:ok, {4, :value, v}}

  defp friendly_dp({:colour, {h, s, v}})
       when is_integer(h) and h in 0..359 and is_integer(s) and s in 0..100 and
              is_integer(v) and v in 0..100,
       do: {:ok, {11, :raw, <<h::16-big, s, v>>}}

  defp friendly_dp({:mode, mode}) when is_map_key(@modes, mode),
    do: {:ok, {2, :enum, Map.fetch!(@modes, mode)}}

  defp friendly_dp({:mode, idx}) when is_integer(idx) and idx in 0..255,
    do: {:ok, {2, :enum, idx}}

  defp friendly_dp({key, _value}) when key in [:on, :brightness, :temp, :colour, :mode],
    do: {:error, {:bad_dp, key}}

  defp friendly_dp({_id, _type, _value} = dp) do
    case Dp.encode([dp]) do
      {:ok, _tlv} -> {:ok, dp}
      {:error, _} -> {:error, {:bad_dp, Dp.shape(dp)}}
    end
  end

  defp friendly_dp({key, _value}), do: {:error, {:bad_dp, Dp.shape(key)}}
  defp friendly_dp(other), do: {:error, {:bad_dp, Dp.shape(other)}}

  defp proper_list?([]), do: true
  defp proper_list?([_ | rest]), do: proper_list?(rest)
  defp proper_list?(_improper), do: false

  @doc """
  Builds a unicast DP set (optionally ack-requesting) for one bulb.

  `dps` as in `friendly_dps/1`. `opts` may include `:ack` (a boolean,
  default `false`; anything else is `{:error, {:bad_option, :ack}}`, as
  is an `opts` that is not a keyword list). Send time is raised to
  `min_send_ms/0`.
  """
  @spec set(P2.addr(), 0..0xFFFF, term(), key(), key(), keyword()) ::
          {:ok, request()} | {:error, term()}
  def set(node_id, sn, dps, local_key, beacon_key, opts \\ []) do
    with {:ok, ack?} <- ack_opt(opts),
         {:ok, dp_list} <- friendly_dps(dps),
         {:ok, tlv} <- Dp.encode(dp_list) do
      request =
        if ack? do
          P2.dp_set_ack(@phone_addr, node_id, sn, tlv, local_key, beacon_key)
        else
          P2.dp_set(@phone_addr, node_id, sn, tlv, local_key, beacon_key)
        end

      {:ok, bump_send(request)}
    end
  end

  @doc "Unicast ping."
  @spec ping(P2.addr(), 0..0xFFFF, key(), key()) :: request()
  def ping(node_id, sn, local_key, beacon_key) do
    bump_send(P2.ping(@phone_addr, node_id, sn, local_key, beacon_key))
  end

  @doc "Unicast OTA reset (bulb returns to unpaired with a new srand)."
  @spec reset(P2.addr(), 0..0xFFFF, key(), key()) :: request()
  def reset(node_id, sn, local_key, beacon_key) do
    bump_send(P2.reset(@phone_addr, node_id, sn, local_key, beacon_key))
  end

  @doc "Add the bulb to local group id `gg` (ack is an A3 group list)."
  @spec group_add(P2.addr(), 0..0xFFFF, byte(), key(), key()) :: request()
  def group_add(node_id, sn, gg, local_key, beacon_key) do
    bump_send(P2.group_add(@phone_addr, node_id, sn, gg, local_key, beacon_key))
  end

  @doc """
  Group DP set to `FFgg`, keyed beaconKey/beaconKey. `gg` is `0..254`:
  255 would make `FF FF`, the mesh broadcast address, not a group.
  `dps` and `opts` as in `set/6`.
  """
  @spec group_set(byte(), 0..0xFFFF, term(), key(), keyword()) ::
          {:ok, request()} | {:error, term()}
  def group_set(gg, sn, dps, beacon_key, opts \\ [])

  def group_set(gg, sn, dps, beacon_key, opts) when gg in 0..254 do
    with {:ok, ack?} <- ack_opt(opts),
         {:ok, dp_list} <- friendly_dps(dps),
         {:ok, tlv} <- Dp.encode(dp_list) do
      dst = <<0xFF, gg>>

      request =
        if ack? do
          P2.dp_set_ack(@phone_addr, dst, sn, tlv, beacon_key, beacon_key)
        else
          P2.dp_set(@phone_addr, dst, sn, tlv, beacon_key, beacon_key)
        end

      {:ok, bump_send(request)}
    end
  end

  def group_set(gg, _sn, _dps, _beacon_key, _opts), do: {:error, {:bad_group, gg}}

  defp ack_opt(opts) do
    with true <- Keyword.keyword?(opts),
         ack? when is_boolean(ack?) <- Keyword.get(opts, :ack, false) do
      {:ok, ack?}
    else
      _ -> {:error, {:bad_option, :ack}}
    end
  end

  defp bump_send({frame, send_ms, window, expect}) do
    {frame, max(send_ms, @min_send_ms), window, expect}
  end
end
