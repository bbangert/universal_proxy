defmodule UniversalProxy.TuyaBeaconMesh.Lights do
  @moduledoc """
  Runtime controller for a Beacon Mesh loaded from an `Inventory`.

  Drop in the JSON dump (`Inventory.decode/1`), start this GenServer with
  a running `Radio`, and call `set/3` / `ping/1` / `status/1`. Sequence
  numbers come from `Seq`; pass `on_persist:` to write the updated
  inventory (including the advanced `seq`) back to Settings whenever a
  block is reserved, groups change or the inventory is reloaded.

  Reports are attributed by **node id → MAC** from the inventory. Import
  rejects duplicate node ids, so twins cannot share a status entry.
  """

  use GenServer

  require Logger

  alias UniversalProxy.TuyaBeaconMesh.{Control, Dp, Inventory, P2, Radio, Seq}

  @type persist_fun :: (Inventory.t() -> any())

  # ── Client API ─────────────────────────────────────────────────────────

  @doc """
  Starts the controller.

  Options:

    * `:inventory` — decoded `Inventory.t()` **or** a JSON binary/map
      (decoded via `Inventory.decode/1`);
    * `:radio` — Radio server name/pid (default `Radio`);
    * `:on_persist` — `fn inventory -> ... end` called after seq/group
      mutations and reloads (default: no-op);
    * `:name` — process name (default `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  @spec set(String.t(), keyword() | map(), keyword()) :: :ok | {:error, term()}
  def set(mac_or_label, dps, opts \\ []) do
    GenServer.call(__MODULE__, {:set, mac_or_label, dps, opts})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @spec ping(String.t()) :: :ok | {:error, term()}
  def ping(mac_or_label) do
    GenServer.call(__MODULE__, {:ping, mac_or_label})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @spec reset(String.t()) :: :ok | {:error, term()}
  def reset(mac_or_label) do
    GenServer.call(__MODULE__, {:reset, mac_or_label})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @spec group_set(String.t() | byte(), keyword() | map(), keyword()) :: :ok | {:error, term()}
  def group_set(name_or_id, dps, opts \\ []) do
    GenServer.call(__MODULE__, {:group_set, name_or_id, dps, opts})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @spec status(String.t()) :: {:ok, map()} | {:error, term()}
  def status(mac_or_label) do
    GenServer.call(__MODULE__, {:status, mac_or_label})
  catch
    :exit, _ -> {:error, :not_running}
  end

  @spec all() :: {:ok, [map()]} | {:error, term()}
  def all do
    GenServer.call(__MODULE__, :all)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @spec inventory() :: {:ok, Inventory.t()} | {:error, term()}
  def inventory do
    GenServer.call(__MODULE__, :inventory)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc """
  Replaces the inventory. For the same mesh (same mesh `beaconKey`) the
  sequence cursor only moves forward: it becomes the later of the dump's
  `seq` and the in-memory cursor (`Seq.advance_to/2`), so reloading an
  older dump never reuses SNs. A different mesh starts from the dump's
  `seq` as-is. Fires `on_persist` with the result.
  """
  @spec reload(Inventory.t() | binary() | map()) :: :ok | {:error, term()}
  def reload(input) do
    GenServer.call(__MODULE__, {:reload, input})
  catch
    :exit, _ -> {:error, :not_running}
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    case decode_inventory(Keyword.fetch!(opts, :inventory)) do
      {:ok, inv} ->
        state = %{
          radio: Keyword.get(opts, :radio, Radio),
          on_persist: Keyword.get(opts, :on_persist, fn _inv -> :ok end),
          beacon_key: inv.beacon_key,
          seq: Seq.new(inv.seq),
          sns: [],
          inventory: inv,
          bulbs: bulbs_from(inv),
          by_node: by_node(inv),
          groups: groups_from(inv)
        }

        {:ok, state, {:continue, :subscribe}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:subscribe, state) do
    case Radio.subscribe(self(), :all, state.radio) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("TuyaBeaconMesh.Lights: radio subscribe failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:set, who, dps, opts}, _from, state) do
    with {:ok, _mac, bulb} <- resolve(state, who),
         {:ok, sn, state} <- take_sn(state),
         {:ok, {frame, send_ms, _w, _e}} <-
           Control.set(bulb.node_id, sn, dps, bulb.local_key, state.beacon_key, opts) do
      {:reply, Radio.send_frame(frame, send_ms, server: state.radio), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ping, who}, _from, state) do
    with {:ok, _mac, bulb} <- resolve(state, who),
         {:ok, sn, state} <- take_sn(state) do
      {frame, send_ms, _w, _e} = Control.ping(bulb.node_id, sn, bulb.local_key, state.beacon_key)
      {:reply, Radio.send_frame(frame, send_ms, server: state.radio), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reset, who}, _from, state) do
    with {:ok, _mac, bulb} <- resolve(state, who),
         {:ok, sn, state} <- take_sn(state) do
      {frame, send_ms, _w, _e} = Control.reset(bulb.node_id, sn, bulb.local_key, state.beacon_key)

      {:reply, Radio.send_frame(frame, send_ms, server: state.radio, class: :control), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:group_set, who, dps, opts}, _from, state) do
    with {:ok, id} <- resolve_group_id(state, who),
         {:ok, sn, state} <- take_sn(state),
         {:ok, {frame, send_ms, _w, _e}} <-
           Control.group_set(id, sn, dps, state.beacon_key, opts) do
      {:reply, Radio.send_frame(frame, send_ms, server: state.radio), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:status, who}, _from, state) do
    case resolve(state, who) do
      {:ok, mac, bulb} -> {:reply, {:ok, public(mac, bulb)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:all, _from, state) do
    {:reply, {:ok, Enum.map(state.bulbs, fn {mac, b} -> public(mac, b) end)}, state}
  end

  def handle_call(:inventory, _from, state) do
    {:reply, {:ok, snapshot(state)}, state}
  end

  def handle_call({:reload, input}, _from, state) do
    case decode_inventory(input) do
      {:ok, inv} ->
        state = %{
          state
          | beacon_key: inv.beacon_key,
            seq: reload_seq(state, inv),
            sns: [],
            inventory: inv,
            bulbs: bulbs_from(inv),
            by_node: by_node(inv),
            groups: groups_from(inv)
        }

        {:reply, :ok, persist(state)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({:tuya_report, report}, state) do
    {:noreply, handle_report(state, report)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── Reports ──────────────────────────────────────────────────────────

  defp handle_report(state, report) do
    with <<_hdr, src::binary-2, _rest::binary>> <- report.frame,
         mac when is_binary(mac) <- Map.get(state.by_node, :binary.decode_unsigned(src)),
         bulb <- Map.fetch!(state.bulbs, mac),
         {:ok, parsed} <- parse(state, bulb, report.frame),
         true <- fresh?(bulb.last_sn, parsed.sn) do
      bulb = %{
        bulb
        | last_sn: parsed.sn,
          last_report_ms: System.monotonic_time(:millisecond)
      }

      bulb = apply_report(bulb, parsed)
      %{state | bulbs: Map.put(state.bulbs, mac, bulb)}
    else
      _ -> state
    end
  end

  defp parse(state, bulb, frame) do
    [bulb.beacon_key, state.beacon_key]
    |> Enum.uniq()
    |> Enum.find_value(:error, fn key ->
      case P2.parse_device(frame, key) do
        {:ok, parsed} -> {:ok, parsed}
        :error -> nil
      end
    end)
  end

  defp fresh?(nil, _sn), do: true

  defp fresh?(last, sn) do
    ahead = rem(sn - last + 65_536, 65_536)
    ahead >= 1 and ahead <= 9_999
  end

  defp apply_report(bulb, %{type: 1, sub_cmd: sub, payload: payload})
       when sub in [7, 9, 10, 11] do
    dps = Map.new(Dp.decode(payload), fn {id, _, v} -> {id, v} end)
    %{bulb | dps: Map.merge(bulb.dps, dps), last_event: {:dp_report, sub}}
  end

  defp apply_report(bulb, %{type: 1, sub_cmd: 2, payload: <<0x01, _::binary>>}),
    do: %{bulb | last_event: :ping_reply}

  defp apply_report(bulb, %{type: 1, sub_cmd: 2, payload: <<0x02, _::binary>>}),
    do: %{bulb | last_event: :reset_ack}

  defp apply_report(bulb, %{type: 1, sub_cmd: 2, payload: <<0xA3, groups::binary>>}) do
    ids = groups |> :binary.bin_to_list() |> Enum.take_while(&(&1 != 0))
    %{bulb | groups: ids, last_event: {:group_list, ids}}
  end

  defp apply_report(bulb, _parsed), do: bulb

  # ── Seq / persist ────────────────────────────────────────────────────

  defp take_sn(state) do
    case state.sns do
      [sn | rest] ->
        {:ok, sn, %{state | sns: rest}}

      [] ->
        case Seq.reserve(state.seq, 32) do
          {:ok, [sn | rest], seq} ->
            state = persist(%{state | seq: seq, sns: rest})
            {:ok, sn, state}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Same mesh: the bulbs have heard everything up to our in-memory cursor
  # (which already sits past any reserved-but-unused block), so a stale or
  # re-dropped dump must not pull it back. A different mesh's bulbs have
  # never heard our counter, and jumping them past their forward window
  # would get every frame dropped, so its dump's cursor is taken as-is.
  defp reload_seq(state, inv) do
    if mesh_id(inv.beacon_key) == mesh_id(state.beacon_key),
      do: Seq.advance_to(state.seq, inv.seq),
      else: Seq.new(inv.seq)
  end

  # `Crypto.key_bytes/1`'s 16-ASCII / 32-hex rule, without raising on a
  # 32-char key that isn't hex (Inventory checks only the length).
  defp mesh_id(<<_::binary-size(32)>> = key) do
    case Base.decode16(key, case: :mixed) do
      {:ok, bytes} -> bytes
      :error -> key
    end
  end

  defp mesh_id(key), do: key

  defp persist(state) do
    inv = snapshot(state)
    _ = state.on_persist.(inv)
    %{state | inventory: inv}
  end

  defp snapshot(state) do
    %{
      state.inventory
      | seq: Seq.value(state.seq),
        bulbs:
          Enum.map(state.bulbs, fn {mac, b} ->
            %{
              mac: mac,
              local_key: b.local_key,
              node_id: b.node_id,
              label: b.label,
              beacon_key: b.beacon_key
            }
          end),
        groups:
          Enum.map(state.groups, fn {id, g} ->
            %{local_id: id, name: g.name, members: g.members}
          end)
    }
  end

  # ── Resolve ──────────────────────────────────────────────────────────

  defp resolve(state, who) do
    mac = normalize_mac(who)

    case Map.fetch(state.bulbs, mac) do
      {:ok, bulb} ->
        {:ok, mac, bulb}

      :error ->
        case Enum.find(state.bulbs, fn {_m, b} -> b.label == who end) do
          {mac, bulb} -> {:ok, mac, bulb}
          nil -> {:error, :unknown_bulb}
        end
    end
  end

  defp resolve_group_id(state, id) when is_integer(id) do
    if Map.has_key?(state.groups, id), do: {:ok, id}, else: {:error, :unknown_group}
  end

  defp resolve_group_id(state, name) when is_binary(name) do
    case Enum.find(state.groups, fn {_id, g} -> g.name == name end) do
      {id, _} -> {:ok, id}
      nil -> {:error, :unknown_group}
    end
  end

  defp resolve_group_id(_, _), do: {:error, :unknown_group}

  defp public(mac, bulb) do
    %{
      mac: mac,
      label: bulb.label,
      node_id: bulb.node_id,
      dps: bulb.dps,
      groups: bulb.groups,
      last_event: bulb.last_event,
      last_report_ms: bulb.last_report_ms
    }
  end

  defp bulbs_from(inv) do
    Map.new(inv.bulbs, fn b ->
      {b.mac,
       %{
         local_key: b.local_key,
         node_id: b.node_id,
         label: b.label,
         beacon_key: b.beacon_key,
         dps: %{},
         groups: nil,
         last_sn: nil,
         last_event: nil,
         last_report_ms: nil
       }}
    end)
  end

  defp by_node(inv), do: Map.new(inv.bulbs, fn b -> {b.node_id, b.mac} end)

  defp groups_from(inv) do
    Map.new(inv.groups, fn g -> {g.local_id, %{name: g.name, members: g.members}} end)
  end

  defp decode_inventory(%{beacon_key: _, bulbs: _} = inv), do: {:ok, inv}
  defp decode_inventory(input), do: Inventory.decode(input)

  defp normalize_mac(mac) when is_binary(mac) do
    mac |> String.replace(~r/[^0-9A-Fa-f]/, "") |> String.upcase()
  end

  defp normalize_mac(_), do: ""
end
