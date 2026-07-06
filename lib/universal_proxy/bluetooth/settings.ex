defmodule UniversalProxy.Bluetooth.Settings do
  @moduledoc """
  DETS-backed persistence for the Bluetooth subsystem's user-facing
  configuration (the `/bluetooth` web tab).

  A single record holding:

      %{
        enabled: boolean(),            # gate HA-facing proxying (espex wiring)
        active_connections: boolean(), # allow HA to open GATT connections
        adapter: String.t() | nil,     # selected proxy radio MAC, nil = auto
        roles: %{mac => role}          # explicit per-adapter role
      }

  where `role` is `:proxy | :audio | :off`:

    * `:proxy` — drives the HA-facing BLE scanner/GATT proxy. At most one
      adapter may be `:proxy` (`set_role/2` enforces this); it's the
      successor to the single `adapter` selector.
    * `:audio` — used by `UniversalProxy.Bluetooth.AudioManager` to
      pair/connect A2DP headsets.
    * `:off` — neither.

  `roles` keys by **MAC** like `adapter`. A record written before this field
  existed is migrated on read (see `migrate_roles/1`): a concrete selected
  `adapter` becomes `:proxy` when `enabled`, else `:off`; an auto (`nil`)
  adapter yields no role entry and `proxy_adapter/1` falls back to the legacy
  `adapter` (still `nil` = auto). So existing BT-proxy behavior is unchanged
  when roles default-derive from a legacy record. `active_connections` stays a
  **proxy-adapter-only** property (a single flag, unchanged).

  `enabled` is NOT a power switch for the radio stack: the BlueZ subtree
  runs whenever the hardware supports it. `enabled` gates only whether the
  scanner/GATT adapters are wired into espex (and therefore whether HA
  sees any Bluetooth data) — see `UniversalProxy.Bluetooth` and
  `UniversalProxy.ESPHome.Supervisor.bluetooth_opts/2`.

  The adapter is keyed by **MAC address** (`"AA:BB:CC:DD:EE:FF"`), not by
  hci index — hci indices are assigned in probe order and are not stable
  across boots or USB hotplug. `nil` means auto-select (first/onboard
  adapter).

  This module is pure persistence: no restarts, no broadcasts. The
  consequences of a settings change (restarting espex so HA sees the new
  feature flags, or restarting the BlueZ subtree on a radio switch)
  belong to `UniversalProxy.Bluetooth`'s public API, which writes here
  first and then acts.

  The DETS file lives on the writable data partition on Nerves
  (`/data/bluetooth_config.dets`) and in `_build/` on the host for
  development. Tests can override via the `:dets_path`, `:table`, and
  `:name` options to `start_link/1` (same shape as
  `UniversalProxy.Audio.Store`).
  """

  use GenServer

  require Logger

  @default_table :bluetooth_config
  @record_key :settings

  @defaults %{enabled: true, active_connections: true, adapter: nil, roles: %{}}

  @mac_format ~r/^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$/

  @roles [:proxy, :audio, :off]

  @type role :: :proxy | :audio | :off
  @type t :: %{
          enabled: boolean(),
          active_connections: boolean(),
          adapter: String.t() | nil,
          roles: %{optional(String.t()) => role()}
        }

  # -- Client API --

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  The current settings, with defaults filled in for any field a stored
  record predates. Returns the defaults map verbatim on a fresh store.
  """
  @spec get(GenServer.server()) :: t()
  def get(server \\ __MODULE__) do
    GenServer.call(server, :get)
  end

  @doc "Compile-time defaults (`#{inspect(@defaults)}`), for defensive callers."
  @spec defaults() :: t()
  def defaults, do: @defaults

  @doc "Persist the master Bluetooth switch."
  @spec set_enabled(GenServer.server(), boolean()) :: :ok | {:error, term()}
  def set_enabled(server \\ __MODULE__, enabled) when is_boolean(enabled) do
    GenServer.call(server, {:put, :enabled, enabled})
  end

  @doc "Persist whether HA may open active (GATT) connections."
  @spec set_active_connections(GenServer.server(), boolean()) :: :ok | {:error, term()}
  def set_active_connections(server \\ __MODULE__, allowed) when is_boolean(allowed) do
    GenServer.call(server, {:put, :active_connections, allowed})
  end

  @doc """
  Persist the selected radio as a MAC address string, or `nil` for auto.

  The MAC is normalized to uppercase (`"aa:bb..."` → `"AA:BB..."`);
  anything that isn't `nil` or a `AA:BB:CC:DD:EE:FF`-shaped string is
  rejected with `{:error, :invalid_adapter}`.
  """
  @spec set_adapter(GenServer.server(), String.t() | nil) :: :ok | {:error, term()}
  def set_adapter(server \\ __MODULE__, adapter) do
    case normalize_adapter(adapter) do
      {:ok, normalized} -> GenServer.call(server, {:put, :adapter, normalized})
      :error -> {:error, :invalid_adapter}
    end
  end

  @doc """
  Set an adapter's role (`:proxy | :audio | :off`), keyed by MAC.

  Assigning `:proxy` demotes any other current `:proxy` adapter to `:off` so
  the single-proxy invariant always holds (only one radio can drive the HA
  proxy). Setting `:off` removes the entry (the default role). Rejects a
  malformed MAC (`{:error, :invalid_adapter}`) or unknown role
  (`{:error, :invalid_role}`).
  """
  @spec set_role(GenServer.server(), String.t(), role()) :: :ok | {:error, term()}
  def set_role(server \\ __MODULE__, mac, role)

  def set_role(server, mac, role) when role in @roles do
    case normalize_adapter(mac) do
      {:ok, normalized} when is_binary(normalized) ->
        GenServer.call(server, {:set_role, normalized, role})

      _ ->
        {:error, :invalid_adapter}
    end
  end

  def set_role(_server, _mac, _role), do: {:error, :invalid_role}

  @doc """
  The proxy adapter MAC: the `:proxy`-role adapter if one is assigned, else the
  legacy `adapter` selector (`nil` = auto). Pure; takes a settings map.

  The legacy fallback is suppressed when the `adapter` radio has since been
  given a non-proxy role: otherwise a radio the user set to `:audio` would still
  read back as the proxy (its `:proxy` fallback masking its `:audio` role),
  which forced "assign some other radio to Proxy first" before an audio toggle
  would stick.
  """
  @spec proxy_adapter(t()) :: String.t() | nil
  def proxy_adapter(%{roles: roles, adapter: adapter}) do
    case Enum.find(roles, fn {_mac, role} -> role == :proxy end) do
      {mac, _role} -> mac
      nil -> if Map.has_key?(roles, adapter), do: nil, else: adapter
    end
  end

  @doc """
  Whether the proxy is role-paused: the user has engaged the role model
  (any explicit role assignment, including `:off`) and `proxy_adapter/1`
  resolves to no radio. Pure; takes a settings map.

  An empty roles map is NOT paused — that's a fresh install or pre-roles
  settings, where the legacy adapter/auto fallback keeps the zero-config
  proxy working. A surviving legacy fallback (roles assigned, but the
  legacy `adapter` radio itself is role-free) also isn't paused — that
  config was proxying before roles existed and must keep doing so. Once
  no fallback remains, an unassigned proxy role means exactly what the
  UI promises: paused until a radio is set to Proxy.
  """
  @spec proxy_paused?(t()) :: boolean()
  def proxy_paused?(%{roles: roles} = settings) do
    roles != %{} and is_nil(proxy_adapter(settings))
  end

  @doc "MACs assigned the `:audio` role. Pure; takes a settings map."
  @spec audio_adapters(t()) :: [String.t()]
  def audio_adapters(%{roles: roles}) do
    for {mac, :audio} <- roles, do: mac
  end

  @doc "Role for a MAC (`:off` if unset). Pure; takes a settings map."
  @spec role(t(), String.t()) :: role()
  def role(%{roles: roles}, mac), do: Map.get(roles, mac, :off)

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, @default_table)
    path = Keyword.get(opts, :dets_path) || dets_path()

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        Logger.info("Bluetooth settings store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("Bluetooth settings store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, read(state.table), state}
  end

  def handle_call({:put, key, value}, _from, state) do
    merged = state.table |> read() |> Map.put(key, value)
    {:reply, persist(state.table, merged, key), state}
  end

  def handle_call({:set_role, mac, role}, _from, state) do
    current = read(state.table)

    {:reply,
     persist(state.table, %{current | roles: apply_role(current.roles, mac, role)}, :roles),
     state}
  end

  # -- Private --

  # Insert+sync a complete record; shared by {:put,...} and {:set_role,...}.
  defp persist(table, record, key) do
    with :ok <- :dets.insert(table, {@record_key, record}),
         :ok <- :dets.sync(table) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Bluetooth settings save failed (#{key}): #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Apply a role with the single-proxy invariant: assigning :proxy clears any
  # other proxy; :off drops the entry (the default role).
  # :off is STORED, not deleted: an explicitly-off radio must be
  # distinguishable from a never-assigned one, or proxy_paused?/1 couldn't
  # tell "user turned their only radio off" (pause) from a fresh install
  # (auto-proxy). It also pins the legacy-adapter suppression in
  # proxy_adapter/1: deleting would resurrect the legacy fallback for the
  # very radio the user just turned off.
  defp apply_role(roles, mac, :off), do: Map.put(roles, mac, :off)

  defp apply_role(roles, mac, :proxy) do
    roles
    |> Enum.reject(fn {_mac, role} -> role == :proxy end)
    |> Map.new()
    |> Map.put(mac, :proxy)
  end

  defp apply_role(roles, mac, role), do: Map.put(roles, mac, role)

  # Merge over the defaults so records written by an older firmware (fewer
  # fields) read back complete, and a corrupt/foreign record degrades to
  # the defaults instead of crashing every reader.
  defp read(table) do
    case :dets.lookup(table, @record_key) do
      [{@record_key, stored}] when is_map(stored) ->
        sanitize(Map.merge(@defaults, migrate_roles(stored)))

      _ ->
        @defaults
    end
  end

  # Records written before the `roles` field existed have no `:roles` key.
  # Synthesize one from the legacy fields so existing proxy behavior is
  # preserved: a concrete selected `adapter` → :proxy when enabled. When
  # disabled (or auto/nil adapter) synthesize NO entry — never :off, which
  # now means "explicitly turned off" and would both suppress the legacy
  # fallback and read as role-paused (proxy_paused?/1); the legacy master
  # toggle gates espex wiring, not the radio selection. Records that
  # already carry `:roles` are returned untouched. Done before the
  # defaults merge so an explicit `roles: %{}` is distinguishable from absence.
  defp migrate_roles(%{roles: _} = stored), do: stored

  defp migrate_roles(stored) do
    roles =
      with {:ok, mac} when is_binary(mac) <- normalize_adapter(Map.get(stored, :adapter)),
           true <- Map.get(stored, :enabled, @defaults.enabled) == true do
        %{mac => :proxy}
      else
        _ -> %{}
      end

    Map.put(stored, :roles, roles)
  end

  # The setters validate writes, but the file can outlive them (corrupt
  # sector, hand-edited DETS, a buggy future firmware). Per-field type
  # validation on READ keeps lifecycle logic safe: a non-boolean `enabled`
  # would otherwise raise BadBooleanError inside the Manager's reconcile.
  # Also drops unknown keys, so readers always get exactly this shape.
  defp sanitize(stored) do
    %{
      enabled: bool_or(stored.enabled, @defaults.enabled),
      active_connections: bool_or(stored.active_connections, @defaults.active_connections),
      adapter: stored_adapter(stored.adapter),
      roles: sanitize_roles(stored.roles)
    }
  end

  # Keep only well-formed `mac => role` pairs (normalized MAC, known role —
  # a stored :off included: it marks "explicitly turned off", which
  # proxy_paused?/1 must distinguish from never-assigned), and enforce the
  # single-proxy invariant on read too, in case a hand-edited/foreign
  # record carries two.
  defp sanitize_roles(roles) when is_map(roles) do
    roles
    |> Enum.flat_map(fn {mac, role} ->
      case normalize_adapter(mac) do
        {:ok, norm} when is_binary(norm) and role in @roles -> [{norm, role}]
        _ -> []
      end
    end)
    |> Enum.reduce({%{}, false}, fn
      # A second :proxy is dropped (absent = :off), preserving the invariant.
      {_mac, :proxy}, {acc, true} -> {acc, true}
      {mac, :proxy}, {acc, false} -> {Map.put(acc, mac, :proxy), true}
      {mac, role}, {acc, seen?} -> {Map.put(acc, mac, role), seen?}
    end)
    |> elem(0)
  end

  defp sanitize_roles(_), do: %{}

  defp bool_or(value, _default) when is_boolean(value), do: value
  defp bool_or(_value, default), do: default

  defp stored_adapter(mac) do
    case normalize_adapter(mac) do
      {:ok, normalized} -> normalized
      :error -> nil
    end
  end

  defp normalize_adapter(nil), do: {:ok, nil}

  defp normalize_adapter(mac) when is_binary(mac) do
    if Regex.match?(@mac_format, mac), do: {:ok, String.upcase(mac)}, else: :error
  end

  defp normalize_adapter(_), do: :error

  defp dets_path do
    if File.dir?("/data") do
      "/data/bluetooth_config.dets"
    else
      Path.join([File.cwd!(), "_build", "bluetooth_config.dets"])
    end
  end
end
