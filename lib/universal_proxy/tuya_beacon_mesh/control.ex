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
  """
  @spec friendly_dps(keyword() | map()) :: {:ok, [Dp.dp()]} | {:error, term()}
  def friendly_dps(dps) when is_map(dps), do: friendly_dps(Map.to_list(dps))

  def friendly_dps(dps) when is_list(dps) do
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

  defp friendly_dp({:mode, mode}) when is_atom(mode) do
    case Map.fetch(@modes, mode) do
      {:ok, idx} -> {:ok, {2, :enum, idx}}
      :error -> {:error, {:bad_mode, mode}}
    end
  end

  defp friendly_dp({:mode, idx}) when is_integer(idx) and idx in 0..255,
    do: {:ok, {2, :enum, idx}}

  defp friendly_dp({key, value}), do: {:error, {:bad_dp, key, value}}

  @doc """
  Builds a unicast DP set (optionally ack-requesting) for one bulb.

  `opts` may include `:ack` (default `false`). Send time is raised to
  `min_send_ms/0`.
  """
  @spec set(P2.addr(), 0..0xFFFF, keyword() | map(), key(), key(), keyword()) ::
          {:ok, request()} | {:error, term()}
  def set(node_id, sn, dps, local_key, beacon_key, opts \\ []) do
    with {:ok, dp_list} <- friendly_dps(dps),
         {:ok, tlv} <- Dp.encode(dp_list) do
      request =
        if Keyword.get(opts, :ack, false) do
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

  @doc "Group DP set to `FFgg`, keyed beaconKey/beaconKey."
  @spec group_set(byte(), 0..0xFFFF, keyword() | map(), key(), keyword()) ::
          {:ok, request()} | {:error, term()}
  def group_set(gg, sn, dps, beacon_key, opts \\ [])

  def group_set(gg, sn, dps, beacon_key, opts) when gg in 0..255 do
    with {:ok, dp_list} <- friendly_dps(dps),
         {:ok, tlv} <- Dp.encode(dp_list) do
      dst = <<0xFF, gg>>

      request =
        if Keyword.get(opts, :ack, false) do
          P2.dp_set_ack(@phone_addr, dst, sn, tlv, beacon_key, beacon_key)
        else
          P2.dp_set(@phone_addr, dst, sn, tlv, beacon_key, beacon_key)
        end

      {:ok, bump_send(request)}
    end
  end

  def group_set(gg, _sn, _dps, _beacon_key, _opts), do: {:error, {:bad_group, gg}}

  defp bump_send({frame, send_ms, window, expect}) do
    {frame, max(send_ms, @min_send_ms), window, expect}
  end
end
