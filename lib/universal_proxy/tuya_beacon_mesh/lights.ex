defmodule UniversalProxy.TuyaBeaconMesh.Lights do
  @moduledoc """
  Runtime controller for a Beacon Mesh loaded from an `Inventory`.

  Start this GenServer with an inventory and a running `Radio`, then call
  `set/3` / `ping/2` / `status/2`. Sequence numbers come from `Seq`.

  ## Inventory and persistence

  `:inventory` is read in `init/1`, so a restarted Lights reads it again.
  Pass a **loader** (`fn -> {:ok, inventory} end` or `{m, f, a}`) that
  reads the current Settings value: a plain inventory in the child spec is
  frozen at supervisor start, and a crash-restart would then resume from
  that old `seq` and reuse sequence numbers the bulbs have already heard
  (they silently drop such frames). A plain inventory is fine for tests.

  `on_persist:` (`(Inventory.t() -> :ok | {:error, term()})`) writes the
  inventory with the advanced `seq` back to Settings whenever a block of
  sequence numbers is reserved or the inventory is reloaded. Only `:ok`
  counts as written. On anything else (an error, another value, a raise)
  nothing is sent, the caller gets `{:error, :persist_failed}`, and the
  next command tries again: no sequence number is used before the cursor
  past it is durable.

  An inventory that doesn't load or validate makes `init/1` return
  `:ignore` (with a warning that carries no key material) rather than
  fail the host's boot.

  ## Commands

  Unicast commands (`set/3`, `ping/2`, `reset/2`) are encrypted with the
  bulb's `localKey` and masked with the bulb's own `beaconKey` (the mesh
  key unless the inventory overrides it); `group_set/3` uses the mesh
  key for both.

  `:ok` from a command means the Radio accepted the frame for
  transmission (on air or queued), not that a bulb acted on it. Queued
  frames for the same bulb or group and the same DPs replace each other
  (latest wins), and the Radio's queue is bounded (`{:error, :queue_full}`).
  When the Radio refuses a frame without transmitting it (`:not_ready`,
  `:not_running`, `:queue_full`, a refused advertise), its sequence number
  is handed out again, so retrying while the Radio is down burns nothing.
  `{:error, :timeout}` means the frame may still go out.

  ## Reports

  Reports are attributed by **node id → MAC** from the inventory, never
  by the advertiser's address (bulbs relay each other's reports). Import
  rejects duplicate node ids, so twins cannot share a status entry.

  Status from reports is **advisory, not authenticated**. Frame integrity
  is an unkeyed CRC-8 over the cleartext source, destination, sequence
  number and sub-command, so anyone who captured one report can rewrite
  those fields and fix up the CRC without any key: re-attribute a report
  to another bulb, replay it, or raise its sequence number to make the
  bulb's later genuine reports look stale. The same holds for our own
  frames: a replayed copy with a higher sequence number can push the
  bulbs' tracker past our counter and deny control. This is a protocol
  limit (`docs/protocols/tuya_beacon_mesh.md` §4.9). Nothing received
  ever moves our transmit `Seq`.

  A report is accepted when its sequence number is 1..9 999 ahead of the
  last one accepted from that bulb (the app's rule). A bulb whose counter
  restarts far behind (or jumps far ahead) would otherwise be ignored
  until it passed the old value, so 3 consecutive in-order reports
  outside the window re-anchor it.

  ## Radio

  The `Radio` subscription is monitored: when the Radio is not running or
  goes down, Lights keeps serving and resubscribes with a backoff (1 s,
  doubling up to 30 s) once it is back. Address the Radio by registered
  name for this to follow a restarted Radio; a pid only ever names one
  incarnation.

  Key material is kept out of `:sys.get_status/1` and crash reports
  (`format_status/1`).
  """

  use GenServer

  require Logger

  alias UniversalProxy.TuyaBeaconMesh.{Control, Crypto, Dp, Inventory, P2, Radio, Seq}

  @type inventory_source ::
          Inventory.t()
          | binary()
          | map()
          | (-> {:ok, Inventory.t() | binary() | map()} | {:error, term()})
          | {module(), atom(), list()}

  @type persist_fun :: (Inventory.t() -> :ok | {:error, term()})

  @block 32
  @resubscribe_ms 1_000
  @max_resubscribe_ms 30_000
  @call_timeout 5_000
  # Shorter than @call_timeout, so a stalled Radio surfaces to the caller
  # as {:error, :timeout} rather than as an exit of the outer call.
  @send_timeout 3_000
  @report_window 9_999
  @group_slots 8
  @resync_reports 3

  # Radio replies after which the frame provably never went on air, so its
  # sequence number can be handed out again.
  @untransmitted [:not_ready, :not_running, :queue_full]

  # ── Client API ─────────────────────────────────────────────────────────

  @doc """
  Starts the controller.

  Options:

    * `:inventory` — an `t:inventory_source/0`: a loader fun / MFA
      returning `{:ok, inventory}` (recommended, see the moduledoc), a
      decoded `Inventory.t()`, or a JSON binary/map. Whatever it gives is
      validated with `Inventory.decode/1`;
    * `:radio` — Radio server name/pid (default `Radio`);
    * `:resubscribe_ms` — first resubscribe delay after the Radio is
      unavailable (default #{@resubscribe_ms}; doubles up to
      #{@max_resubscribe_ms});
    * `:on_persist` — a `t:persist_fun/0` (default: no-op `:ok`);
    * `:name` — process name (default `#{inspect(__MODULE__)}`).

  Every client function takes `server:` (default `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "DP set for one bulb (by MAC or label). `opts`: `:ack` (default `false`), `:server`."
  @spec set(String.t(), keyword() | map(), keyword()) :: :ok | {:error, term()}
  def set(mac_or_label, dps, opts \\ []) do
    {server, opts} = Keyword.pop(opts, :server, __MODULE__)
    call(server, {:set, mac_or_label, dps, opts})
  end

  @spec ping(String.t(), keyword()) :: :ok | {:error, term()}
  def ping(mac_or_label, opts \\ []), do: call(opts, {:ping, mac_or_label})

  @spec reset(String.t(), keyword()) :: :ok | {:error, term()}
  def reset(mac_or_label, opts \\ []), do: call(opts, {:reset, mac_or_label})

  @doc "Group DP set (by group name or local id). `opts`: `:ack`, `:server`."
  @spec group_set(String.t() | byte(), keyword() | map(), keyword()) :: :ok | {:error, term()}
  def group_set(name_or_id, dps, opts \\ []) do
    {server, opts} = Keyword.pop(opts, :server, __MODULE__)
    call(server, {:group_set, name_or_id, dps, opts})
  end

  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(mac_or_label, opts \\ []), do: call(opts, {:status, mac_or_label})

  @spec all(keyword()) :: {:ok, [map()]} | {:error, term()}
  def all(opts \\ []), do: call(opts, :all)

  @doc "The current inventory, keys included, with the persisted-form `seq`."
  @spec inventory(keyword()) :: {:ok, Inventory.t()} | {:error, term()}
  def inventory(opts \\ []), do: call(opts, :inventory)

  @doc """
  Replaces the inventory (validated with `Inventory.decode/1`). For the
  same mesh (same mesh `beaconKey`) the sequence cursor only moves
  forward: it becomes the later of the dump's `seq` and the in-memory
  cursor (`Seq.advance_to/2`), so reloading an older dump never reuses
  SNs. A different mesh starts from the dump's `seq` as-is. The result is
  written through `on_persist` first; if that fails nothing changes and
  the reply is `{:error, :persist_failed}`.
  """
  @spec reload(Inventory.t() | binary() | map(), keyword()) :: :ok | {:error, term()}
  def reload(input, opts \\ []), do: call(opts, {:reload, input})

  defp call(opts, request) when is_list(opts),
    do: call(Keyword.get(opts, :server, __MODULE__), request)

  # `catch :exit` idiom (CLAUDE.md), with timeouts kept apart: a command
  # that timed out may still have been sent.
  defp call(server, request) do
    GenServer.call(server, request, @call_timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _reason -> {:error, :not_running}
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    case load_inventory(Keyword.fetch!(opts, :inventory)) do
      {:ok, inv} ->
        state =
          %{
            radio: Keyword.get(opts, :radio, Radio),
            radio_mon: nil,
            resubscribe_ms: Keyword.get(opts, :resubscribe_ms, @resubscribe_ms),
            backoff_ms: Keyword.get(opts, :resubscribe_ms, @resubscribe_ms),
            on_persist: Keyword.get(opts, :on_persist, fn _inv -> :ok end),
            seq: Seq.new(inv.seq),
            sns: []
          }
          |> load(inv)

        {:ok, state, {:continue, :subscribe}}

      {:error, reason} ->
        Logger.warning(
          "TuyaBeaconMesh.Lights: not starting, inventory unusable (#{inspect(reason)})"
        )

        :ignore
    end
  end

  defp load_inventory({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a),
    do: run_loader(fn -> apply(m, f, a) end)

  defp load_inventory(fun) when is_function(fun, 0), do: run_loader(fun)
  defp load_inventory(input), do: Inventory.decode(input)

  # Whatever the loader returned or raised may hold the dump (a
  # Jason.DecodeError carries its whole input), so only a category of it
  # is kept. Inventory.decode/1's own errors carry no input.
  defp run_loader(fun) do
    case fun.() do
      {:ok, input} -> Inventory.decode(input)
      {:error, reason} -> {:error, {:loader, loader_error(reason)}}
      _other -> {:error, {:loader, :bad_return}}
    end
  rescue
    e -> {:error, {:loader, {:raised, e.__struct__}}}
  catch
    kind, _ -> {:error, {:loader, kind}}
  end

  defp loader_error(reason) when is_atom(reason), do: reason
  defp loader_error(%{__exception__: true, __struct__: module}), do: {:exception, module}

  defp loader_error(reason) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: elem(reason, 0)

  defp loader_error(_reason), do: :error

  # Replaces everything derived from the inventory; the caller sets `seq`.
  defp load(state, inv) do
    Map.merge(state, %{
      inventory: inv,
      beacon_key: inv.beacon_key,
      bulbs: bulbs_from(inv),
      by_node: Map.new(inv.bulbs, &{&1.node_id, &1.mac}),
      groups: Map.new(inv.groups, &{&1.local_id, &1})
    })
  end

  @impl GenServer
  def handle_continue(:subscribe, state), do: {:noreply, subscribe(state)}

  # Monitor before subscribing so a Radio that dies right after accepting
  # the subscription still delivers its :DOWN.
  defp subscribe(state) do
    with pid when is_pid(pid) <- GenServer.whereis(state.radio),
         mon = Process.monitor(pid),
         :ok <- subscribe_or_demonitor(pid, mon) do
      %{state | radio_mon: mon, backoff_ms: state.resubscribe_ms}
    else
      {:error, reason} -> retry_subscribe(state, reason)
      _not_registered -> retry_subscribe(state, :not_running)
    end
  end

  defp subscribe_or_demonitor(pid, mon) do
    case Radio.subscribe(self(), :all, server: pid) do
      :ok ->
        :ok

      {:error, reason} ->
        Process.demonitor(mon, [:flush])
        {:error, reason}
    end
  end

  defp retry_subscribe(state, reason) do
    # Only the first miss of a run is worth a line; retries stay quiet.
    if state.backoff_ms == state.resubscribe_ms do
      Logger.warning(
        "TuyaBeaconMesh.Lights: radio unavailable (#{inspect(reason)}), retrying subscribe"
      )
    end

    Process.send_after(self(), :resubscribe, state.backoff_ms)
    %{state | radio_mon: nil, backoff_ms: min(state.backoff_ms * 2, @max_resubscribe_ms)}
  end

  @impl GenServer
  def handle_call({:set, who, dps, opts}, _from, state) do
    case resolve(state, who) do
      {:ok, _mac, bulb} ->
        build = &Control.set(bulb.node_id, &1, dps, bulb.local_key, bulb.beacon_key, opts)
        transmit(state, build, coalesce: {:set, bulb.node_id, dp_keys(dps)})

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:ping, who}, _from, state) do
    case resolve(state, who) do
      {:ok, _mac, bulb} ->
        build = &{:ok, Control.ping(bulb.node_id, &1, bulb.local_key, bulb.beacon_key)}
        transmit(state, build, coalesce: {:ping, bulb.node_id})

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:reset, who}, _from, state) do
    case resolve(state, who) do
      {:ok, _mac, bulb} ->
        build = &{:ok, Control.reset(bulb.node_id, &1, bulb.local_key, bulb.beacon_key)}
        transmit(state, build, class: :control)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:group_set, who, dps, opts}, _from, state) do
    case resolve_group_id(state, who) do
      {:ok, id} ->
        build = &Control.group_set(id, &1, dps, state.beacon_key, opts)
        transmit(state, build, coalesce: {:group_set, id, dp_keys(dps)})

      {:error, reason} ->
        {:reply, {:error, reason}, state}
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
    with {:ok, inv} <- Inventory.decode(input),
         reloaded = load(%{state | seq: reload_seq(state, inv), sns: []}, inv),
         :ok <- persist(reloaded) do
      {:reply, :ok, reloaded}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({:tuya_report, report}, state) do
    {:noreply, handle_report(state, report)}
  end

  def handle_info(:resubscribe, %{radio_mon: nil} = state), do: {:noreply, subscribe(state)}

  def handle_info({:DOWN, mon, :process, _pid, reason}, %{radio_mon: mon} = state) do
    {:noreply, retry_subscribe(%{state | radio_mon: nil}, {:radio_down, reason})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      {:state, s} -> {:state, redact_state(s)}
      {:message, m} -> {:message, redact_message(m)}
      {:queue, q} when is_list(q) -> {:queue, Enum.map(q, &redact_message/1)}
      {:log, log} when is_list(log) -> {:log, Enum.map(log, &redact_log_entry/1)}
      {:reason, r} -> {:reason, redact_reason(r)}
      other -> other
    end)
  end

  # ── Transmit ─────────────────────────────────────────────────────────

  # Takes a sequence number, builds the frame with it and hands it to the
  # Radio. An SN is given back (pushed back onto the reserved block) only
  # when the frame provably never went on air: the build failed, or the
  # Radio refused it before transmitting (@untransmitted, or a refused
  # advertise). It is the most recently taken SN and every SN still in the
  # block is newer than anything transmitted, so handing it out again keeps
  # the on-air sequence strictly increasing; the persisted cursor already
  # sits past the whole block. A timeout or a Radio that died mid-call
  # keeps the SN used, since the frame may have gone out.
  defp transmit(state, build, send_opts) do
    with {:ok, sn, state} <- take_sn(state),
         {:ok, {frame, send_ms, _window, _expect}} <- build_with(build, sn, state) do
      opts = [server: state.radio, timeout: @send_timeout] ++ send_opts

      case Radio.send_frame(frame, send_ms, opts) do
        :ok ->
          {:reply, :ok, state}

        {:error, reason} = error when reason in @untransmitted ->
          {:reply, error, give_back(state, sn)}

        {:error, {:advertise, _}} = error ->
          {:reply, error, give_back(state, sn)}

        {:error, _} = error ->
          {:reply, error, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:build_error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp build_with(build, sn, state) do
    case build.(sn) do
      {:ok, request} -> {:ok, request}
      {:error, reason} -> {:build_error, reason, give_back(state, sn)}
    end
  end

  defp give_back(state, sn), do: %{state | sns: [sn | state.sns]}

  defp dp_keys(dps) when is_map(dps), do: dps |> Map.keys() |> Enum.sort()
  defp dp_keys(dps) when is_list(dps), do: dps |> Enum.map(&dp_key/1) |> Enum.sort()
  defp dp_keys(_dps), do: []

  defp dp_key({key, _value}), do: key
  defp dp_key(other), do: other

  # ── Reports ──────────────────────────────────────────────────────────

  defp handle_report(state, report) do
    with <<_hdr, src::binary-2, _rest::binary>> <- report.frame,
         mac when is_binary(mac) <- Map.get(state.by_node, :binary.decode_unsigned(src)),
         bulb = Map.fetch!(state.bulbs, mac),
         {:ok, parsed} <- parse(state, bulb, report.frame) do
      case check_fresh(bulb, parsed.sn) do
        :accept ->
          bulb = %{
            bulb
            | last_sn: parsed.sn,
              resync: nil,
              last_report_ms: System.monotonic_time(:millisecond)
          }

          put_bulb(state, mac, apply_report(bulb, parsed))

        {:hold, resync} ->
          put_bulb(state, mac, %{bulb | resync: resync})

        :ignore ->
          state
      end
    else
      _ -> state
    end
  end

  defp put_bulb(state, mac, bulb), do: %{state | bulbs: Map.put(state.bulbs, mac, bulb)}

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

  # A report is fresh when 1..9 999 ahead of the last accepted one. Outside
  # that, @resync_reports consecutive in-order (each fresh relative to the
  # one before) reports re-anchor the bulb; repeats change nothing.
  defp check_fresh(%{last_sn: nil}, _sn), do: :accept

  defp check_fresh(%{last_sn: last, resync: resync}, sn) do
    cond do
      fresh?(last, sn) -> :accept
      sn == last -> :ignore
      true -> resync_step(resync, sn)
    end
  end

  defp resync_step({sn, _count}, sn), do: :ignore

  defp resync_step({prev, count}, sn) do
    cond do
      not fresh?(prev, sn) -> {:hold, {sn, 1}}
      count + 1 >= @resync_reports -> :accept
      true -> {:hold, {sn, count + 1}}
    end
  end

  defp resync_step(nil, sn), do: {:hold, {sn, 1}}

  defp fresh?(last, sn), do: Integer.mod(sn - last, 65_536) in 1..@report_window

  defp apply_report(bulb, %{type: 1, sub_cmd: sub, payload: payload})
       when sub in [7, 9, 10, 11] do
    dps = Map.new(Dp.decode(payload), fn {id, _, v} -> {id, v} end)
    %{bulb | dps: Map.merge(bulb.dps, dps), last_event: {:dp_report, sub}}
  end

  defp apply_report(bulb, %{type: 1, sub_cmd: 2, payload: <<0x01, _::binary>>}),
    do: %{bulb | last_event: :ping_reply}

  defp apply_report(bulb, %{type: 1, sub_cmd: 2, payload: <<0x02, _::binary>>}),
    do: %{bulb | last_event: :reset_ack}

  # P[1..9) is exactly 8 one-byte group slots, 0 = empty, in any order;
  # the bytes after it are not group ids.
  defp apply_report(bulb, %{type: 1, sub_cmd: 2, payload: <<0xA3, groups::binary>>}) do
    ids =
      groups
      |> binary_part(0, min(byte_size(groups), @group_slots))
      |> :binary.bin_to_list()
      |> Enum.reject(&(&1 == 0))

    %{bulb | groups: ids, last_event: {:group_list, ids}}
  end

  defp apply_report(bulb, _parsed), do: bulb

  # ── Seq / persist ────────────────────────────────────────────────────

  # A new block is persisted before any of its SNs is used; when that
  # fails the state is left as it was, so the next call tries the same
  # block again.
  defp take_sn(%{sns: [sn | rest]} = state), do: {:ok, sn, %{state | sns: rest}}

  defp take_sn(state) do
    {:ok, [sn | rest], seq} = Seq.reserve(state.seq, @block)
    reserved = %{state | seq: seq, sns: rest}

    with :ok <- persist(reserved), do: {:ok, sn, reserved}
  end

  # Same mesh: the bulbs have heard everything up to our in-memory cursor
  # (which already sits past any reserved-but-unused block), so a stale or
  # re-dropped dump must not pull it back. A different mesh's bulbs have
  # never heard our counter, and jumping them past their forward window
  # would get every frame dropped, so its dump's cursor is taken as-is.
  defp reload_seq(state, inv) do
    if Crypto.key_bytes(inv.beacon_key) == Crypto.key_bytes(state.beacon_key),
      do: Seq.advance_to(state.seq, inv.seq),
      else: Seq.new(inv.seq)
  end

  defp persist(state) do
    case run_persist(state.on_persist, snapshot(state)) do
      :ok ->
        :ok

      failure ->
        Logger.warning(
          "TuyaBeaconMesh.Lights: on_persist failed (#{failure}); not using unpersisted sequence numbers"
        )

        {:error, :persist_failed}
    end
  end

  # Describes a failure without echoing what on_persist returned or
  # raised, which may hold the inventory.
  defp run_persist(fun, inv) do
    case fun.(inv) do
      :ok -> :ok
      {:error, reason} when is_atom(reason) -> "error #{inspect(reason)}"
      {:error, _reason} -> "error"
      _other -> "unexpected return value"
    end
  rescue
    e -> "raised #{inspect(e.__struct__)}"
  catch
    kind, _ -> "#{kind}"
  end

  defp snapshot(state), do: %{state.inventory | seq: Seq.value(state.seq)}

  # ── Redaction ────────────────────────────────────────────────────────

  defp redact_state(%{bulbs: bulbs} = state) when is_map(bulbs) do
    bulbs =
      Map.new(bulbs, fn {mac, b} -> {mac, %{b | local_key: :redacted, beacon_key: :redacted}} end)

    %{state | bulbs: bulbs, inventory: :redacted, beacon_key: :redacted}
  end

  defp redact_state(_other), do: :redacted

  defp redact_message({:"$gen_call", from, request}),
    do: {:"$gen_call", from, redact_request(request)}

  defp redact_message(message), do: redact_request(message)

  defp redact_request({:reload, _input}), do: {:reload, :redacted}
  defp redact_request(request), do: request

  defp redact_log_entry(entry) when is_tuple(entry) do
    entry
    |> Tuple.to_list()
    |> Enum.map(fn
      %{bulbs: _} = state -> redact_state(state)
      {:ok, %Inventory{}} -> {:ok, :redacted}
      other -> redact_message(other)
    end)
    |> List.to_tuple()
  end

  defp redact_log_entry(entry), do: entry

  # Stack frames can carry call arguments (keys among them): keep arities.
  defp redact_reason({reason, [_ | _] = stack}) do
    {redact_exception(reason), Enum.map(stack, &arity_frame/1)}
  end

  defp redact_reason(reason), do: redact_exception(reason)

  defp redact_exception(%FunctionClauseError{} = e), do: %{e | args: nil}
  defp redact_exception(reason), do: reason

  defp arity_frame({m, f, args, loc}) when is_list(args), do: {m, f, length(args), loc}
  defp arity_frame(frame), do: frame

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
         resync: nil,
         last_event: nil,
         last_report_ms: nil
       }}
    end)
  end

  defp normalize_mac(mac) when is_binary(mac) do
    mac |> String.replace(~r/[^0-9A-Fa-f]/, "") |> String.upcase()
  end

  defp normalize_mac(_), do: ""
end
