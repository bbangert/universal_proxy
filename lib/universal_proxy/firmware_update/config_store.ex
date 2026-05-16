defmodule UniversalProxy.FirmwareUpdate.ConfigStore do
  @moduledoc """
  DETS-backed persistence for firmware-update configuration overrides.

  Stores operator-set values that override the v1 defaults. The store
  itself is intentionally simple: it persists to DETS and replies to
  reads. It does **not** call back into the live `Updater` GenServer —
  that propagation is the facade's job (see
  `UniversalProxy.FirmwareUpdate.update_config/1`).

  The DETS file lives on the writable data partition on Nerves
  (`/data/firmware_update.dets`) and in `_build/` on the host for
  development.

  ## Defaults

  - `:repo` — `"bbangert/universal_proxy"`
  - `:github_token` — `nil` (60 req/hr anonymous rate limit)
  - `:public_key` — `nil` (falls back to reading
    `rootfs_overlay/etc/firmware_signing.pub` from disk)
  - `:verification_required` — `false` (v1 default; flipped per device
    by the operator after Phase 6 ships the real KMS public key)
  """

  use GenServer

  require Logger

  @config_key :settings
  @pubkey_size 32
  @placeholder_pubkey <<0::size(@pubkey_size * 8)>>

  @defaults %{
    repo: "bbangert/universal_proxy",
    github_token: nil,
    public_key: nil,
    verification_required: false
  }

  @config_fields Map.keys(@defaults)

  # -- Client API --

  def start_link(opts \\ []) do
    gen_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec get_repo(GenServer.server()) :: String.t()
  def get_repo(server \\ __MODULE__) do
    GenServer.call(server, :get_repo)
  end

  @spec get_token(GenServer.server()) :: String.t() | nil
  def get_token(server \\ __MODULE__) do
    GenServer.call(server, :get_token)
  end

  @doc """
  Returns the 32-byte Ed25519 public key.

  Resolution order:

  1. ConfigStore override (`:public_key`) if set.
  2. Contents of the on-disk signing key file (`/etc/firmware_signing.pub`
     on a device; `rootfs_overlay/etc/firmware_signing.pub` on host).
  3. `nil` if neither is present.

  Reading the file lives here so the library (`Signature`, `Updater`) stays
  configuration-free.
  """
  @spec get_public_key(GenServer.server()) :: <<_::256>> | nil
  def get_public_key(server \\ __MODULE__) do
    GenServer.call(server, :get_public_key)
  end

  @spec verification_required?(GenServer.server()) :: boolean()
  def verification_required?(server \\ __MODULE__) do
    GenServer.call(server, :verification_required?)
  end

  @doc """
  Persist the given keyword list of overrides. Unknown keys are ignored.

  Returns `:ok | {:error, term()}`. Does **not** propagate the change to
  the live Updater — callers should use the facade
  (`UniversalProxy.FirmwareUpdate.update_config/1`) for that.
  """
  @spec put(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def put(server \\ __MODULE__, updates) when is_list(updates) do
    GenServer.call(server, {:put, updates})
  end

  @doc """
  Return a fully-resolved snapshot (defaults + overrides + on-disk pubkey
  fallback). Used by `Application.start/2` to seed the library Supervisor.
  """
  @spec snapshot(GenServer.server()) :: %{
          repo: String.t(),
          github_token: String.t() | nil,
          public_key: <<_::256>> | nil,
          verification_required: boolean()
        }
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  # -- Server Callbacks --

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, :firmware_update_config)
    path = Keyword.get(opts, :dets_path) || dets_path()
    pubkey_path = Keyword.get(opts, :pubkey_path) || default_pubkey_path()

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        Logger.info("Firmware update config store opened at #{path}")
        {:ok, %{table: table, pubkey_path: pubkey_path}}

      {:error, reason} ->
        Logger.error("Firmware update config store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}) do
    :dets.close(table)
  end

  @impl true
  def handle_call(:get_repo, _from, state) do
    {:reply, current(state).repo, state}
  end

  def handle_call(:get_token, _from, state) do
    {:reply, current(state).github_token, state}
  end

  def handle_call(:get_public_key, _from, state) do
    {:reply, resolve_public_key(state), state}
  end

  def handle_call(:verification_required?, _from, state) do
    {:reply, current(state).verification_required, state}
  end

  def handle_call(:snapshot, _from, state) do
    snap = state |> current() |> Map.put(:public_key, resolve_public_key(state))
    {:reply, snap, state}
  end

  def handle_call({:put, updates}, _from, state) do
    sanitized = sanitize(updates)
    overrides = state.table |> read_overrides() |> Map.merge(sanitized)

    with :ok <- :dets.insert(state.table, {@config_key, overrides}),
         :ok <- :dets.sync(state.table) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("Firmware update config store write failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # -- Private --

  defp current(state) do
    Map.merge(@defaults, read_overrides(state.table))
  end

  defp read_overrides(table) do
    case :dets.lookup(table, @config_key) do
      [{@config_key, overrides}] when is_map(overrides) -> overrides
      _ -> %{}
    end
  end

  defp resolve_public_key(state) do
    case current(state).public_key do
      <<_::binary-size(@pubkey_size)>> = key -> key
      nil -> read_pubkey_file(state.pubkey_path)
      _ -> nil
    end
  end

  defp read_pubkey_file(path) do
    case File.read(path) do
      {:ok, <<key::binary-size(@pubkey_size)>>} -> key
      {:ok, _other} -> nil
      {:error, _} -> nil
    end
  end

  defp sanitize(updates) do
    updates
    |> Enum.flat_map(fn
      {k, v} when k in @config_fields ->
        case normalize(k, v) do
          :skip -> []
          normalized -> [{k, normalized}]
        end

      _ ->
        []
    end)
    |> Map.new()
  end

  defp normalize(:repo, v) when is_binary(v) do
    case String.trim(v) do
      "" -> :skip
      trimmed -> trimmed
    end
  end

  defp normalize(:github_token, nil), do: nil

  defp normalize(:github_token, v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(:public_key, nil), do: nil
  defp normalize(:public_key, <<_::binary-size(@pubkey_size)>> = key), do: key

  defp normalize(:public_key, v) do
    Logger.warning(
      "Firmware update public_key must be a 32-byte binary; got #{inspect(v)}; ignoring"
    )

    :skip
  end

  defp normalize(:verification_required, v) when is_boolean(v), do: v

  defp normalize(key, v) do
    Logger.warning(
      "Firmware update config #{inspect(key)} got unsupported value #{inspect(v)}; ignoring"
    )

    :skip
  end

  defp dets_path do
    if File.dir?("/data") do
      "/data/firmware_update.dets"
    else
      Path.join([File.cwd!(), "_build", "firmware_update.dets"])
    end
  end

  defp default_pubkey_path do
    if File.dir?("/data") do
      "/etc/firmware_signing.pub"
    else
      Path.join([File.cwd!(), "rootfs_overlay", "etc", "firmware_signing.pub"])
    end
  end

  @doc false
  def placeholder_pubkey, do: @placeholder_pubkey
end
