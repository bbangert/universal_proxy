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

  `on_persist:` (`t:persist_fun/0`) writes the inventory with the
  advanced `seq` back to Settings whenever a new lease of sequence
  numbers is taken or the inventory is reloaded. Only `:ok` counts as
  written. On anything else (an error, another value, a raise) nothing is
  sent, the caller gets `{:error, :persist_failed}`, and the next command
  tries again: no sequence number is used before the cursor past it is
  durable. Every persist is a flash write on the host, so they are
  rate-limited (below).

  An inventory that doesn't load or validate makes `init/1` return
  `:ignore` (with a warning that carries no key material) rather than
  fail the host's boot.

  ## Sequence leases

  Numbers are handed out from memory while the in-memory cursor is behind
  a persisted **lease** end; the persisted `seq` is always that lease end,
  so a crash resumes at or past every number ever used. When the lease
  runs out, a new one is persisted before any number in it is used.

  A new lease is sized for one persist per `:persist_interval_ms`: the
  numbers the last lease held, divided by how long it lasted, times the
  interval, times 1.5, clamped to `[:min_lease, :max_lease]`. The first
  lease after a start or reload is `:min_lease`. A lease that runs out
  before the interval has passed is followed by a `:max_lease` one at
  once (correctness first), so writes exceed one per interval only above
  `:max_lease` frames per interval.

  A restart after a crash or power loss resumes at the persisted lease
  end, so what bounds the bulbs' jump is how far that end is past the
  last frame they can have heard. The lease size alone doesn't bound it:
  the Radio coalesces queued frames for the same bulb and DPs, so a burst
  hands out many numbers while one frame stays on air. Lights therefore
  enforces

      persisted lease end - aired <= :max_jump   (serial distance)

  where `aired` is the last number the Radio reports it put on air (its
  `:last_tx_sn`, read with the readiness check before each lease; queued,
  coalesced and uncertain frames don't count), or the number before the
  cursor after a start or a cursor-moving reload. After a start the
  Radio's first report counts even when lower (within `:max_jump`): a
  Radio that outlived the previous Lights may still have an older frame
  on air and newer ones queued. A lease that would
  pass that is cut short to end at it, and when nothing fits the command
  gets `{:error, :busy}` (retryable; nothing persisted, nothing queued):
  frames the Radio would have coalesced away anyway. Once a newer frame
  airs, leases fit again. `:max_jump` defaults to, and is capped at,
  `Seq.max_jump/0` (900): the bulbs accepted jumps of about 900
  (`docs/protocols/tuya_beacon_mesh.md` §4.3). `:max_lease` (at most
  `Seq.max_lease/0`, 899) must stay below it.

  So one crash jumps the bulbs at most `:max_jump` past the last frame
  known on air. The bound is per crash: a restarted Lights whose first
  lease (`:min_lease`) is abandoned too (its first frame refused, then
  another crash before any of it airs) resumes at that lease's end, so
  `k` such restarts in a row add at most `k * :min_lease`. Only a crash
  loop accumulates, at the pace the supervisors' restart budgets allow.
  To keep it rare, no lease is taken while the Radio reports it can't
  transmit (not ready or not running: the command gets that error and
  nothing is persisted), and a command that can't be built takes no
  number; a Radio that drops right after that check is the residual
  case. So are frames that went out with an uncertain outcome, and
  frames the Radio dropped unaired (a `:control` send, the Radio losing
  readiness): once it has nothing on air or queued, waiting for them
  would refuse every command, so the baseline moves to the cursor.

  A lease persist that fails may still have reached the store (a write
  that lands before its sync fails), and a host store refuses a `seq`
  behind the one it holds. So the largest lease end attempted since the
  last successful persist is remembered, and every retry (and a same-mesh
  reload) proposes an end at or past it. That end is never more than
  `:max_lease` past the cursor, so the jump bound holds; using numbers up
  to it is safe whether or not it was written.

  On a clean stop (`:normal`, `:shutdown`, `{:shutdown, _}`; Lights traps
  exits so a supervisor shutdown reaches `terminate/2`), the unused rest
  of the lease is handed back through the optional `on_tighten:`
  (`t:tighten_fun/0`), so a planned restart doesn't jump the bulbs
  forward. It is called as `on_tighten.(inventory, leased)`:
  `inventory.seq` is the in-memory cursor, the next number Lights would
  have used, or the cursor of a same-mesh reload that failed if that is
  later (it may be stored, or heard from the app, already); `leased` is
  the lease end the last `on_persist` wrote. When that reload cursor is
  at or past `leased`, nothing is tightened. A
  host store should apply it only when its stored `seq` still equals
  `leased` (nothing else wrote since) and the mesh is the one stored; the
  `seq` it then stores moves **back**, to a value at or ahead of every
  number ever used. That holds because every number handed to the Radio
  (sent, queued, or with an uncertain outcome) is behind the cursor and a
  number goes back to the cursor only when its frame provably never went
  out. After a crash `terminate/2` may see state that predates numbers
  handed to the Radio, so nothing is tightened then. A tighten that fails,
  is refused or takes over 4 s changes nothing: the lease end stays
  persisted, which is always safe. Without `on_tighten` nothing is
  tightened.

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
  `:not_running`, `:queue_full`, a refused advertise `{:advertise, _}`),
  or the frame can't be built, its sequence number is handed out again,
  so retrying while the Radio is down burns nothing. Every other error
  keeps the number used: reusing a number the bulbs may have heard gets
  the next command dropped as stale, while skipping one costs nothing.
  `{:error, :busy}` means too many frames are waiting behind the one on
  air (see "Sequence leases"): nothing was queued, retry later.
  `{:error, :timeout}` means the frame may still go out; `{:error, {:uncertain, reason}}` means the Radio lost
  `Bluez.Mgmt` or its lease during the advertise, so the frame may have
  gone out (the Radio re-runs setup).

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

  Each bulb has two times (`:clock` milliseconds, in `all/1` and
  `status/2`): `last_report_ms`, when a report was last accepted, and
  `heard_ms`, when a frame that parses under the bulb's keys last came
  from it, accepted or held for re-anchoring (an exact repeat of the last
  sequence number doesn't count). A held frame changes nothing else (no
  DPs, no sequence tracking beyond the re-anchor count), but it shows the
  bulb is there: right after a power cycle the bulb's first answers are
  held, and presence must not read them as silence. Like every report,
  `heard_ms` is advisory (see above).

  ## Radio

  The `Radio` subscription is monitored: when the Radio is not running or
  goes down, Lights keeps serving and resubscribes with a backoff (1 s,
  doubling up to 30 s) once it is back. Address the Radio by registered
  name for this to follow a restarted Radio; a pid only ever names one
  incarnation.

  ## Bad input and key material

  Every request is validated before anything is leased, persisted or
  sent: a bad bulb, group, DP list (`Control.friendly_dps/1`, which also
  takes raw `{id, type, value}` DPs) or option is an `{:error, reason}`
  reply, an unknown request `{:error, :unknown_request}`, and stray casts
  and messages are ignored. None of them stops Lights.

  Keys are held **sealed** (`UniversalProxy.TuyaBeaconMesh.Redact`): the
  inventory and every bulb's keys sit in the state as opaque closures,
  opened only to build or parse a frame or to persist, so neither
  `:sys.get_state/1` nor the raw `:sys` debug log (`{:out, reply, to,
  state}` and the like, which `format_status/1` never sees) can print
  them. `reload/2` sends its input sealed and `inventory/1`'s reply
  travels sealed, opened in the caller. `format_status/1` redacts what
  remains, and every callback runs under `Redact.guard/2`, so a crash
  leaves a key-free exit reason (supervisor reports print it raw). A
  plain inventory in the child spec is printed by supervisor reports as
  given; the host passes a loader.
  """

  use GenServer

  require Logger

  alias UniversalProxy.TuyaBeaconMesh.{Control, Crypto, Dp, Inventory, P2, Radio, Redact, Seq}

  @type inventory_source ::
          Inventory.t()
          | binary()
          | map()
          | (-> {:ok, Inventory.t() | binary() | map()} | {:error, term()})
          | {module(), atom(), list()}

  @type persist_fun :: (Inventory.t() -> :ok | {:error, term()})
  @type tighten_fun :: (Inventory.t(), leased :: non_neg_integer() -> :ok | {:error, term()})

  @persist_interval_ms 60_000
  @min_lease 32
  @max_lease 600
  # Bounds terminate/2's tighten so it ends inside @shutdown_ms; a tighten
  # cut short is harmless (the lease end stays persisted).
  @tighten_timeout 4_000
  @shutdown_ms 5_000
  @resubscribe_ms 1_000
  @max_resubscribe_ms 30_000
  @call_timeout 5_000
  # Shorter than @call_timeout, so a stalled Radio surfaces to the caller
  # as {:error, :timeout} rather than as an exit of the outer call.
  @send_timeout 3_000
  # A status check before each new lease; short, since it delays the call.
  @ready_timeout 1_000
  @report_window 9_999
  @group_slots 8
  @resync_reports 3

  # Radio replies after which the frame provably never went on air, so its
  # sequence number can be handed out again. {:uncertain, _} is not one.
  @untransmitted [:not_ready, :not_running, :queue_full]

  @label "TuyaBeaconMesh.Lights"
  # Requests whose second element is an inventory (format_status/1).
  @inventory_requests [:reload]

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
    * `:on_tighten` — a `t:tighten_fun/0` called on a clean stop (default:
      none, nothing is tightened); see "Sequence leases";
    * `:persist_interval_ms` — the target time between persists (positive
      integer, default #{@persist_interval_ms});
    * `:min_lease` / `:max_lease` — bounds of a lease (default
      #{@min_lease} / #{@max_lease}; `1 <= min_lease <= max_lease <=
      #{Seq.max_lease()}`);
    * `:max_jump` — the most the persisted lease end may be past the
      last frame known on air (default and cap #{Seq.max_jump()}, the
      largest jump known to be accepted; above `:max_lease`);
    * `:clock` — `(-> integer())` monotonic milliseconds (default
      `System.monotonic_time(:millisecond)`; a test seam);
    * `:name` — process name (default `#{inspect(__MODULE__)}`).

  An option outside those bounds stops the start with `{:error,
  {:bad_option, key}}`.

  Every client function takes `server:` (default `#{inspect(__MODULE__)}`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  # The shutdown leaves room for terminate/2's one bounded tighten.
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      shutdown: @shutdown_ms
    }
  end

  @doc """
  DP set for one bulb (by MAC or label). `dps`: friendly keys or raw DP
  tuples (`Control.friendly_dps/1`). `opts`: `:ack` (a boolean, default
  `false`), `:server`.
  """
  @spec set(String.t(), keyword() | map() | [Dp.dp()], keyword()) :: :ok | {:error, term()}
  def set(mac_or_label, dps, opts \\ []) do
    with {:ok, server, opts} <- split_server(opts),
         do: call_server(server, {:set, mac_or_label, dps, opts})
  end

  @spec ping(String.t(), keyword()) :: :ok | {:error, term()}
  def ping(mac_or_label, opts \\ []), do: call(opts, {:ping, mac_or_label})

  @spec reset(String.t(), keyword()) :: :ok | {:error, term()}
  def reset(mac_or_label, opts \\ []), do: call(opts, {:reset, mac_or_label})

  @doc "Group DP set (by group name or local id). `dps` and `opts` as in `set/3`."
  @spec group_set(String.t() | byte(), keyword() | map() | [Dp.dp()], keyword()) ::
          :ok | {:error, term()}
  def group_set(name_or_id, dps, opts \\ []) do
    with {:ok, server, opts} <- split_server(opts),
         do: call_server(server, {:group_set, name_or_id, dps, opts})
  end

  @spec status(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(mac_or_label, opts \\ []), do: call(opts, {:status, mac_or_label})

  @spec all(keyword()) :: {:ok, [map()]} | {:error, term()}
  def all(opts \\ []), do: call(opts, :all)

  @doc """
  The current inventory, keys included, with the persisted-form `seq`.
  The reply travels sealed and is opened here, in the caller, which then
  holds the keys in the clear: keep it out of logs, state and messages.
  """
  @spec inventory(keyword()) :: {:ok, Inventory.t()} | {:error, term()}
  def inventory(opts \\ []) do
    with {:ok, sealed} <- call(opts, :inventory), do: {:ok, Redact.unseal(sealed)}
  end

  @doc """
  Replaces the inventory (validated with `Inventory.decode/1`). For the
  same mesh (same mesh `beaconKey`) the sequence cursor only moves
  forward: it becomes the later of the dump's `seq` and the in-memory
  cursor (`Seq.advance_to/2`), so reloading an older dump never reuses
  SNs. A different mesh starts from the dump's `seq` as-is. The result is
  written through `on_persist` first; if that fails nothing changes and
  the reply is `{:error, :persist_failed}`. Once a different mesh is
  written, the old mesh's frames still on air or queued are dropped
  (`Radio.clear_tx/1`).
  """
  @spec reload(Inventory.t() | binary() | map(), keyword()) :: :ok | {:error, term()}
  def reload(input, opts \\ []), do: call(opts, {:reload, Redact.seal(input)})

  # Opts that aren't a keyword list name no server: refused here, before
  # anything is sent.
  defp split_server(opts) do
    if Keyword.keyword?(opts),
      do: {:ok, Keyword.get(opts, :server, __MODULE__), Keyword.delete(opts, :server)},
      else: {:error, :bad_opts}
  end

  defp call(opts, request) do
    with {:ok, server, _opts} <- split_server(opts), do: call_server(server, request)
  end

  # `catch :exit` idiom (CLAUDE.md), with timeouts kept apart: a command
  # that timed out may still have been sent.
  defp call_server(server, request) do
    GenServer.call(server, request, @call_timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _reason -> {:error, :not_running}
  end

  # ── GenServer ────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts), do: Redact.guard(@label, fn -> do_init(opts) end)

  defp do_init(opts) do
    with {:ok, leasing} <- lease_opts(opts),
         {:ok, inv} <- load_inventory(Keyword.fetch!(opts, :inventory)) do
      # Only so a supervisor shutdown runs terminate/2 (the tighten).
      # Nothing long-lived is linked; a stray EXIT falls through
      # handle_info.
      Process.flag(:trap_exit, true)

      state =
        %{
          radio: Keyword.get(opts, :radio, Radio),
          radio_mon: nil,
          resubscribe_ms: Keyword.get(opts, :resubscribe_ms, @resubscribe_ms),
          backoff_ms: Keyword.get(opts, :resubscribe_ms, @resubscribe_ms),
          on_persist: Keyword.get(opts, :on_persist, fn _inv -> :ok end),
          seq: Seq.new(inv.seq),
          lease: nil,
          attempted: nil,
          tighten_floor: nil,
          aired: before(inv.seq),
          aired_seen?: false
        }
        |> Map.merge(leasing)
        |> load(inv)

      {:ok, state, {:continue, :subscribe}}
    else
      {:error, {:bad_option, _key} = reason} ->
        {:stop, reason}

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

  defp lease_opts(opts) do
    interval = Keyword.get(opts, :persist_interval_ms, @persist_interval_ms)
    min = Keyword.get(opts, :min_lease, @min_lease)
    max = Keyword.get(opts, :max_lease, @max_lease)
    jump = Keyword.get(opts, :max_jump, Seq.max_jump())
    on_tighten = Keyword.get(opts, :on_tighten)
    clock = Keyword.get(opts, :clock, &monotonic_ms/0)

    # In order: later checks rely on max_lease having passed.
    checks = [
      persist_interval_ms: fn -> is_integer(interval) and interval > 0 end,
      max_lease: fn -> is_integer(max) and max in 1..Seq.max_lease() end,
      min_lease: fn -> is_integer(min) and min in 1..max end,
      max_jump: fn -> is_integer(jump) and jump > max and jump <= Seq.max_jump() end,
      on_tighten: fn -> is_nil(on_tighten) or is_function(on_tighten, 2) end,
      clock: fn -> is_function(clock, 0) end
    ]

    case Enum.find(checks, fn {_key, valid?} -> not valid?.() end) do
      {key, _valid?} ->
        {:error, {:bad_option, key}}

      nil ->
        {:ok,
         %{
           interval_ms: interval,
           min_lease: min,
           max_lease: max,
           max_jump: jump,
           on_tighten: on_tighten,
           clock: clock
         }}
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  # Replaces everything derived from the inventory; the caller sets `seq`.
  # The inventory and the bulbs' keys are kept sealed (see the moduledoc).
  defp load(state, inv) do
    Map.merge(state, %{
      inventory: Redact.seal(inv),
      bulbs: bulbs_from(inv),
      by_node: Map.new(inv.bulbs, &{&1.node_id, &1.mac}),
      groups: Map.new(inv.groups, &{&1.local_id, &1})
    })
  end

  defp mesh_key(state), do: Redact.unseal(state.inventory).beacon_key

  @impl GenServer
  def handle_continue(:subscribe, state),
    do: Redact.guard(@label, fn -> {:noreply, subscribe(state)} end)

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
  def handle_call(request, _from, state),
    do: Redact.guard(@label, fn -> do_call(request, state) end)

  # Each clause checks its target and DPs and replies with an error for a
  # bad one; frames are built before any SN is taken (transmit/3), so a
  # command that can't be built (bad options included) uses nothing.
  defp do_call({:set, who, dps, opts}, state) do
    with {:ok, _mac, bulb} <- resolve(state, who),
         {:ok, dp_list} <- Control.friendly_dps(dps) do
      build = unicast(bulb, &Control.set(bulb.node_id, &1, dp_list, &2, &3, opts))
      transmit(state, build, coalesce: {:set, bulb.node_id, dp_ids(dp_list)})
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp do_call({:ping, who}, state) do
    case resolve(state, who) do
      {:ok, _mac, bulb} ->
        build = unicast(bulb, &{:ok, Control.ping(bulb.node_id, &1, &2, &3)})
        transmit(state, build, coalesce: {:ping, bulb.node_id})

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_call({:reset, who}, state) do
    case resolve(state, who) do
      {:ok, _mac, bulb} ->
        build = unicast(bulb, &{:ok, Control.reset(bulb.node_id, &1, &2, &3)})
        transmit(state, build, class: :control)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp do_call({:group_set, who, dps, opts}, state) do
    with {:ok, id} <- resolve_group_id(state, who),
         {:ok, dp_list} <- Control.friendly_dps(dps) do
      build = &Control.group_set(id, &1, dp_list, mesh_key(state), opts)
      transmit(state, build, coalesce: {:group_set, id, dp_ids(dp_list)})
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp do_call({:status, who}, state) do
    case resolve(state, who) do
      {:ok, mac, bulb} -> {:reply, {:ok, public(mac, bulb)}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp do_call(:all, state) do
    {:reply, {:ok, Enum.map(state.bulbs, fn {mac, b} -> public(mac, b) end)}, state}
  end

  # Sealed: the debug log records replies (inventory/1 opens it).
  defp do_call(:inventory, state) do
    {:reply, {:ok, Redact.seal(snapshot(state))}, state}
  end

  defp do_call({:reload, input}, state) do
    case input |> Redact.unseal() |> Inventory.decode() do
      {:ok, inv} -> apply_reload(state, inv)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp do_call(_unknown, state), do: {:reply, {:error, :unknown_request}, state}

  # A builder for transmit/3 that opens the bulb's keys only to build.
  defp unicast(bulb, build) do
    fn sn ->
      {local_key, mask} = Redact.unseal(bulb.keys)
      build.(sn, local_key, mask)
    end
  end

  @impl GenServer
  def handle_cast(_msg, state), do: {:noreply, state}

  @impl GenServer
  def handle_info(message, state), do: Redact.guard(@label, fn -> do_info(message, state) end)

  defp do_info({:tuya_report, report}, state) do
    {:noreply, handle_report(state, report)}
  end

  defp do_info(:resubscribe, %{radio_mon: nil} = state), do: {:noreply, subscribe(state)}

  defp do_info({:DOWN, mon, :process, _pid, reason}, %{radio_mon: mon} = state) do
    {:noreply, retry_subscribe(%{state | radio_mon: nil}, {:radio_down, reason})}
  end

  defp do_info(_other, state), do: {:noreply, state}

  # A clean stop runs between callbacks, so state holds every SN handed to
  # the Radio. A crash's state can predate SNs the crashing callback
  # handed out, so tightening to its cursor could reuse one: not done.
  @impl GenServer
  def terminate(reason, state) do
    Redact.guard(@label, fn ->
      if clean_stop?(reason), do: tighten(state)
      :ok
    end)
  end

  defp clean_stop?(:normal), do: true
  defp clean_stop?(:shutdown), do: true
  defp clean_stop?({:shutdown, _}), do: true
  defp clean_stop?(_reason), do: false

  @impl GenServer
  def format_status(status), do: Redact.format_status(status, @inventory_requests)

  # ── Transmit ─────────────────────────────────────────────────────────

  # Builds the frame with the next sequence number, then takes that number
  # (leasing first if needed) and hands the frame to the Radio. Building
  # first means a command that can't be built never makes Lights persist
  # a lease for it. An SN is given back (the cursor moves back onto it)
  # only when the Radio provably never put the frame on air
  # (@untransmitted, or a refused advertise). It is the SN taken in this
  # same call, and every SN after it is unused, so handing it out again
  # keeps the on-air sequence strictly increasing; the persisted lease end
  # already sits past it. A timeout, a Radio that died mid-call or an
  # {:uncertain, _} advertise keeps the SN used (behind the cursor), since
  # the frame may have gone out: that is what makes tightening to the
  # cursor safe.
  defp transmit(state, build, send_opts) do
    sn = Seq.next(state.seq)

    # take_sn/1 hands out the cursor (a new lease starts there), so the
    # frame built above carries the SN taken.
    with {:ok, {frame, send_ms, _window, _expect}} <- build.(sn),
         {:ok, ^sn, state} <- take_sn(state) do
      opts = [server: state.radio, timeout: @send_timeout] ++ send_opts

      {reply, state} =
        case Radio.send_frame(frame, send_ms, opts) do
          :ok -> {:ok, state}
          {:error, reason} = error when reason in @untransmitted -> {error, give_back(state, sn)}
          {:error, {:advertise, _}} = error -> {error, give_back(state, sn)}
          {:error, _} = error -> {error, state}
        end

      {:reply, reply, retire_floor(state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp give_back(state, sn), do: %{state | seq: Seq.give_back(state.seq, sn)}

  # The DPs a frame sets, by id: friendly and raw forms of one DP
  # coalesce alike, and no value enters the key.
  defp dp_ids(dp_list), do: dp_list |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.uniq()

  # ── Reports ──────────────────────────────────────────────────────────

  defp handle_report(state, %{frame: frame}) do
    with <<_hdr, src::binary-2, _rest::binary>> <- frame,
         mac when is_binary(mac) <- Map.get(state.by_node, :binary.decode_unsigned(src)),
         bulb = Map.fetch!(state.bulbs, mac),
         {:ok, parsed} <- parse(state, bulb, frame) do
      case check_fresh(bulb, parsed.sn) do
        :accept ->
          now = state.clock.()

          bulb = %{
            bulb
            | last_sn: parsed.sn,
              resync: nil,
              last_report_ms: now,
              heard_ms: now
          }

          put_bulb(state, mac, apply_report(bulb, parsed))

        # Held for re-anchoring: heard, nothing applied.
        {:hold, resync} ->
          put_bulb(state, mac, %{bulb | resync: resync, heard_ms: state.clock.()})

        :ignore ->
          state
      end
    else
      _ -> state
    end
  end

  defp handle_report(state, _malformed), do: state

  defp put_bulb(state, mac, bulb), do: %{state | bulbs: Map.put(state.bulbs, mac, bulb)}

  defp parse(state, bulb, frame) do
    {_local_key, mask} = Redact.unseal(bulb.keys)

    [mask, mesh_key(state)]
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

  # SNs come from the persisted lease. Once it is used up, a new lease is
  # persisted before any SN in it is used; when that fails only the
  # attempted end is kept (below), so the next call tries again.
  defp take_sn(state) do
    case Seq.take(state.seq) do
      {:ok, sn, seq} ->
        {:ok, sn, %{state | seq: seq}}

      {:error, :lease_exhausted} ->
        with {:ok, state, idle?} <- radio_ready(state),
             {:ok, state} <- new_lease(state, idle?) do
          {:ok, sn, seq} = Seq.take(state.seq)
          {:ok, sn, %{state | seq: seq}}
        end
    end
  end

  # A lease persisted for a frame the Radio then refuses is abandoned if
  # Lights stops before using it, and each abandoned lease adds to the
  # bulbs' jump after a crash. So no lease is taken while the Radio says
  # it can't transmit; a Radio that drops right after this check is the
  # residual case. One status call per lease, not per frame; it also
  # brings the last SN known on air.
  defp radio_ready(state) do
    case Radio.status(server: state.radio, timeout: @ready_timeout) do
      {:ok, %{ready: true} = status} ->
        idle? = status.tx == nil and status.queued == 0
        {:ok, observe_aired(state, status.last_tx_sn), idle?}

      {:ok, _not_ready} ->
        {:error, :not_ready, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  # `aired` is the last SN known to have gone on air: one the Radio
  # reports it advertised, taken when it is one Lights handed out since
  # the baseline (after `aired`, before `next`). Queued, coalesced or
  # uncertain frames never count. The baseline after a start is the
  # number before the cursor, but a Radio that outlived the previous
  # Lights may still have an older frame on air with newer ones queued:
  # its first report after a start is taken even when lower (within
  # max_jump behind the cursor). A cursor-moving reload's baseline comes
  # from the dump instead and is only ever raised.
  defp observe_aired(%{aired_seen?: false} = state, sn) when is_integer(sn) do
    if Integer.mod(Seq.next(state.seq) - sn, 65_536) in 1..state.max_jump//1,
      do: %{state | aired: sn, aired_seen?: true},
      else: %{state | aired_seen?: true}
  end

  defp observe_aired(state, sn) when is_integer(sn) do
    if Seq.ahead?(state.aired, sn) and Seq.ahead?(sn, Seq.next(state.seq)),
      do: %{state | aired: sn},
      else: state
  end

  defp observe_aired(state, _none), do: state

  defp before(cursor), do: Integer.mod(cursor - 1, 65_536)

  defp new_lease(state, idle?) do
    now = state.clock.()

    with {:ok, seq, state} <- admit(state, lease_seq(state, now), idle?) do
      leased = %{state | seq: seq}

      case persist(leased) do
        :ok ->
          size = Seq.remaining(seq)
          Logger.debug("TuyaBeaconMesh.Lights: leased #{size} sequence numbers")
          {:ok, %{leased | lease: {size, now}, attempted: nil}}

        {:error, reason} ->
          {:error, reason, %{state | attempted: Seq.value(seq)}}
      end
    end
  end

  # Admission against what went on air: a persisted lease end never more
  # than max_jump past `aired`, so a crash's restart (at the lease end) is
  # at most max_jump past the last frame the bulbs can have heard. The
  # lease cap alone doesn't bound that: the Radio coalesces queued frames
  # for the same bulb and DPs, so a burst can hand out many SNs while one
  # frame stays on air. A lease that would pass the limit is cut to end at
  # it; when nothing fits (or a failed attempt already went further) the
  # command gets {:error, :busy}, nothing persisted or queued. Those are
  # frames the Radio would have coalesced away; once a newer frame airs,
  # leases fit again.
  #
  # A Radio with nothing on air and nothing queued will never air the SNs
  # between `aired` and `next`: it dropped them unaired (a :control send,
  # or losing readiness empties the queue). Waiting would refuse every
  # command for good, so the baseline moves to the number before `next`
  # and the lease fits again. Such dropped frames, like uncertain ones
  # that aired after all, are where the bulbs' jump can exceed max_jump.
  defp admit(state, proposal, idle?) do
    limit = rem(state.aired + state.max_jump, 65_536)
    next = Seq.next(state.seq)

    cond do
      not Seq.ahead?(limit, Seq.value(proposal)) ->
        {:ok, proposal, state}

      Seq.ahead?(next, limit) and
          not (is_integer(state.attempted) and Seq.ahead?(limit, state.attempted)) ->
        {:ok, clamped} = Seq.lease(state.seq, Integer.mod(limit - next, 65_536))
        {:ok, clamped, state}

      idle? ->
        Logger.debug("TuyaBeaconMesh.Lights: radio idle with SNs never aired; rebasing")
        {:ok, proposal, %{state | aired: before(next), aired_seen?: true}}

      true ->
        {:error, :busy, state}
    end
  end

  # The next lease: sized by lease_size/2, and never ending before an end
  # a failed persist attempted. Such a write may have reached the store
  # (DETS inserts, then its sync fails), which then refuses any seq behind
  # it, so a shorter retry would block sending for good. The attempted
  # end was a lease from this same cursor (next only moves once a persist
  # succeeds), so covering it stays within max_lease.
  defp lease_seq(state, now) do
    {:ok, seq} =
      state.seq |> cover_attempted(state.attempted) |> Seq.lease(lease_size(state, now))

    seq
  end

  # Extends the lease to `attempted`. One that is not ahead of the cursor,
  # or further ahead than a lease, can't come from a lease attempt from
  # here and is ignored.
  defp cover_attempted(seq, nil), do: seq

  defp cover_attempted(seq, attempted) do
    case Seq.lease(seq, Integer.mod(attempted - Seq.next(seq), 65_536)) do
      {:ok, covered} -> covered
      {:error, _not_a_lease} -> seq
    end
  end

  # Only called once the current lease is used up, so the last lease's
  # size is what was used since it was persisted. A lease that lasted less
  # than the interval was sized for a lower rate than the one now seen:
  # the next is max_lease, which keeps writes at one per interval up to
  # max_lease numbers per interval.
  defp lease_size(%{lease: nil} = state, _now), do: state.min_lease

  defp lease_size(%{lease: {used, since}} = state, now) do
    elapsed = now - since

    if elapsed < state.interval_ms do
      state.max_lease
    else
      # ceil(used / elapsed * interval * 1.5)
      wanted = div(used * state.interval_ms * 3 + 2 * elapsed - 1, 2 * elapsed)
      wanted |> max(state.min_lease) |> min(state.max_lease)
    end
  end

  # Same mesh: the bulbs may have heard everything up to our in-memory
  # cursor, so a stale or re-dropped dump must not pull it back, and the
  # persisted lease end never moves back either (a host store refuses
  # that outside a tighten), including an end a failed persist attempted;
  # the rest of the lease stays usable. A different mesh's bulbs have
  # never heard our counter, and jumping them past their forward window
  # would get every frame dropped, so its dump's cursor is taken as-is,
  # with no lease.
  #
  # A failed same-mesh reload keeps its end as attempted when that is
  # within a lease of the cursor, like a failed lease. One further ahead
  # (a newer dump) can't be covered by a lease; retrying the reload
  # proposes it again.
  defp apply_reload(state, inv) do
    same_mesh? = Crypto.key_bytes(inv.beacon_key) == Crypto.key_bytes(mesh_key(state))

    seq =
      if same_mesh?,
        do: state.seq |> cover_attempted(state.attempted) |> Seq.advance_to(inv.seq),
        else: Seq.new(inv.seq)

    floor = if same_mesh?, do: state.tighten_floor
    reloaded = load(%{state | seq: seq, lease: nil, attempted: nil, tighten_floor: floor}, inv)

    case persist(reloaded) do
      :ok ->
        unless same_mesh?, do: clear_old_mesh_tx(state)
        {:reply, :ok, reloaded |> rebase_aired(state, same_mesh?) |> retire_floor()}

      {:error, reason} when same_mesh? ->
        state =
          state
          |> note_reload_attempt(Seq.value(seq))
          |> Map.put(:tighten_floor, later_floor(state.tighten_floor, Seq.next(seq)))

        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # A failed same-mesh reload leaves `next` where it was, but its cursor
  # may be stored anyway (a write that lands before its sync fails) and,
  # coming from the dump, may be what the bulbs heard from the app. A
  # tighten must not go below it, or a restart would resend numbers the
  # bulbs drop as stale; tighten/1 uses the latest such cursor as its
  # floor. (Moving `next` up to it would be safe only inside the persisted
  # lease, and a failed reload changes nothing else, so it stays put.)
  # Retired once `next` reaches the floor through kept sends or a reload:
  # tightening to `next` is then at or past it anyway, and a floor kept
  # would read as ahead again once `next` is half the 16-bit range on.
  # Only checked after a send's outcome, since `next` is briefly past the
  # floor before a refused frame gives its SN back.
  defp retire_floor(%{tighten_floor: floor} = state) when is_integer(floor) do
    if Seq.ahead?(Seq.next(state.seq), floor), do: state, else: %{state | tighten_floor: nil}
  end

  defp retire_floor(state), do: state

  # The old mesh's frames still on air or queued would go out under keys
  # the new mesh doesn't know, and the Radio would report their SNs as the
  # new mesh's progress (letting leases run past max_jump while the new
  # frames wait). Dropping them and the reported SN with them keeps
  # `aired` the new mesh's own. A Radio that doesn't answer is down or
  # wedged and airs nothing either way. (The host's upload path restarts
  # the whole mesh, Radio included, so only reload/2 needs this.)
  defp clear_old_mesh_tx(state) do
    _ = Radio.clear_tx(server: state.radio, timeout: @ready_timeout)
    :ok
  end

  # A reload that moved the cursor (a newer dump, another mesh) takes the
  # number before it as the baseline: the dump says the app got there.
  defp rebase_aired(reloaded, state, same_mesh?) do
    if same_mesh? and Seq.next(reloaded.seq) == Seq.next(state.seq),
      do: reloaded,
      else: %{reloaded | aired: before(Seq.next(reloaded.seq)), aired_seen?: true}
  end

  defp later_floor(nil, cursor), do: cursor
  defp later_floor(floor, cursor), do: if(Seq.ahead?(floor, cursor), do: cursor, else: floor)

  defp note_reload_attempt(state, until) do
    if Integer.mod(until - Seq.next(state.seq), 65_536) in 1..state.max_lease//1,
      do: %{state | attempted: until},
      else: state
  end

  # Runs on_tighten in a task so a stuck host store can't hold terminate/2
  # past the supervisor's shutdown. Whatever happens, the stored cursor is
  # either the lease end or the tightened one, and both are safe.
  defp tighten(%{on_tighten: nil}), do: :ok

  defp tighten(state) do
    leased = Seq.value(state.seq)
    tight = Seq.tighten(state.seq, state.tighten_floor)

    if Seq.value(tight) != leased do
      {on_tighten, inv} = {state.on_tighten, snapshot(%{state | seq: tight})}
      task = Task.async(fn -> run_persist(&on_tighten.(&1, leased), inv) end)

      case Task.yield(task, @tighten_timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, :ok} ->
          Logger.debug("TuyaBeaconMesh.Lights: tightened seq #{leased} -> #{Seq.value(tight)}")

        {:ok, failure} ->
          Logger.debug("TuyaBeaconMesh.Lights: tighten failed (#{failure}); seq stays #{leased}")

        _exit_or_timeout ->
          Logger.debug("TuyaBeaconMesh.Lights: tighten did not finish; seq stays #{leased}")
      end
    end

    :ok
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

  defp snapshot(state), do: %{Redact.unseal(state.inventory) | seq: Seq.value(state.seq)}

  # ── Resolve ──────────────────────────────────────────────────────────

  # Only a MAC-shaped `who` (Inventory's rule) is looked up as a MAC, so a
  # label never gets read as hex pulled out of it.
  defp resolve(state, who) do
    with {:ok, mac} <- Inventory.normalize_mac(who),
         {:ok, bulb} <- Map.fetch(state.bulbs, mac) do
      {:ok, mac, bulb}
    else
      :error -> resolve_label(state, who)
    end
  end

  # Bulbs without a label hold nil, so only a binary is matched: a nil or
  # other non-string `who` must not resolve to the first unlabelled bulb.
  defp resolve_label(state, who) when is_binary(who) do
    case Enum.find(state.bulbs, fn {_m, b} -> b.label == who end) do
      {mac, bulb} -> {:ok, mac, bulb}
      nil -> {:error, :unknown_bulb}
    end
  end

  defp resolve_label(_state, _who), do: {:error, :unknown_bulb}

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
      last_report_ms: bulb.last_report_ms,
      heard_ms: bulb.heard_ms
    }
  end

  defp bulbs_from(inv) do
    Map.new(inv.bulbs, fn b ->
      {b.mac,
       %{
         keys: Redact.seal({b.local_key, b.beacon_key}),
         node_id: b.node_id,
         label: b.label,
         dps: %{},
         groups: nil,
         last_sn: nil,
         resync: nil,
         last_event: nil,
         last_report_ms: nil,
         heard_ms: nil
       }}
    end)
  end
end
