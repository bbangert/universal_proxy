defmodule UniversalProxy.Storage.Settings do
  @moduledoc """
  DETS-backed persistence for USB backup storage configuration.

  Two kinds of records share one table:

    * Per-drive settings, keyed `{slot_sub, vendor_id, product_id}` — the
      same shape as `UniversalProxy.Audio.Store` and `UniversalProxy.UART`
      stores. Value shape:

          %{
            share_enabled?: boolean(),
            share_folder: String.t(),
            friendly_name: String.t() | nil,
            last_seen_at: integer() | nil
          }

      `share_folder` is the drive-relative directory the SMB share maps
      to: `"/"` (the default) is the drive root, anything else is a
      relative path of plain segments (`"backups/ha"`). Records written
      before the field existed read back as `"/"` — `get_drive/2` merges
      the defaults over whatever is stored.

    * One global Samba credentials record (fixed key `:credentials`):

          %{
            username: String.t(),
            password: String.t(),
            provisioned_hash: String.t() | nil,
            rotated_at: integer() | nil
          }

      The password is generated lazily the first time `credentials/1` is
      called — `:crypto.strong_rand_bytes(15) |> Base.encode32(padding:
      false)`, a 24-character, 120-bit-entropy secret — persisted, and
      returned unchanged on every later read (including after a restart).
      `rotate_password/1` replaces it with a fresh random value and clears
      `provisioned_hash` so `UniversalProxy.Storage.Smbd` reprovisions the
      smbd user. Never log or inspect this record: the password lives
      inside it.

  The DETS file lives on the writable data partition on Nerves
  (`/data/storage_settings.dets`) and in `_build/` on the host for
  development. Tests can override via the `:dets_path`, `:table`, and
  `:name` options to `start_link/1`.
  """

  use GenServer

  require Logger

  @default_table :storage_settings
  @credentials_key :credentials
  @username "backup"

  @type slot_sub :: String.t()
  @type vendor_id :: String.t() | nil
  @type product_id :: String.t() | nil
  @type drive_key :: {slot_sub(), vendor_id(), product_id()}

  @type drive_settings :: %{
          share_enabled?: boolean(),
          share_folder: String.t(),
          friendly_name: String.t() | nil,
          last_seen_at: integer() | nil
        }

  @type credentials :: %{
          username: String.t(),
          password: String.t(),
          provisioned_hash: String.t() | nil,
          rotated_at: integer() | nil
        }

  @drive_defaults %{
    share_enabled?: false,
    share_folder: "/",
    friendly_name: nil,
    last_seen_at: nil
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
  Child spec for supervision. Mirrors `UniversalProxy.Audio.Store` so the
  module can be dropped straight into a supervisor's children list.
  """
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  @doc "Look up a drive's settings. Unknown keys return the defaults."
  @spec get_drive(GenServer.server(), drive_key()) :: drive_settings()
  def get_drive(server \\ __MODULE__, {slot_sub, _vid, _pid} = key) when is_binary(slot_sub) do
    GenServer.call(server, {:get_drive, key})
  end

  @doc """
  Merge a partial update into a drive's settings, applying defaults for
  any field not already stored and not present in `params`.
  """
  @spec put_drive(GenServer.server(), drive_key(), map()) :: :ok | {:error, term()}
  def put_drive(server \\ __MODULE__, {slot_sub, _vid, _pid} = key, params)
      when is_binary(slot_sub) and is_map(params) do
    GenServer.call(server, {:put_drive, key, params})
  end

  @doc "Whether a drive's Samba share is enabled."
  @spec share_enabled?(GenServer.server(), drive_key()) :: boolean()
  def share_enabled?(server \\ __MODULE__, key), do: get_drive(server, key).share_enabled?

  @doc """
  Return the global Samba credentials, generating and persisting the
  password on first read. The returned password is stable across
  subsequent reads and process restarts until `rotate_password/1` is
  called. Never log or inspect the return value.
  """
  @spec credentials(GenServer.server()) :: credentials()
  def credentials(server \\ __MODULE__), do: GenServer.call(server, :credentials)

  @doc """
  Replace the stored password with a freshly generated random value,
  clear `provisioned_hash` (forcing `Storage.Smbd` to reprovision the
  smbd user), and stamp `rotated_at`. Returns the new credentials record.
  """
  @spec rotate_password(GenServer.server()) :: credentials()
  def rotate_password(server \\ __MODULE__), do: GenServer.call(server, :rotate_password)

  @doc """
  Store the SHA-256 hash smbd was last provisioned with, so
  `Storage.Smbd` can skip reprovisioning when it hasn't changed.
  """
  @spec put_provisioned_hash(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def put_provisioned_hash(server \\ __MODULE__, hash) when is_binary(hash) do
    GenServer.call(server, {:put_provisioned_hash, hash})
  end

  # -- Server callbacks --

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table, @default_table)
    path = Keyword.get(opts, :dets_path) || dets_path()
    File.mkdir_p!(Path.dirname(path))

    case :dets.open_file(table_name, file: to_charlist(path), type: :set) do
      {:ok, table} ->
        # Constrain perms: the global credentials record's password lives
        # here, unencrypted.
        _ = File.chmod(path, 0o600)
        Logger.info("Storage settings store opened at #{path}")
        {:ok, %{table: table}}

      {:error, reason} ->
        Logger.error("Storage settings store failed to open #{path}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{table: table}), do: :dets.close(table)

  @impl true
  def handle_call({:get_drive, key}, _from, state) do
    {:reply, lookup_drive(state.table, key), state}
  end

  def handle_call({:put_drive, key, params}, _from, state) do
    merged = Map.merge(lookup_drive(state.table, key), take_drive_fields(params))

    with :ok <- :dets.insert(state.table, {key, merged}),
         :ok <- :dets.sync(state.table) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("Storage settings save failed for #{inspect(key)}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:credentials, _from, state) do
    case lookup_credentials(state.table) do
      {:ok, creds} ->
        {:reply, creds, state}

      :error ->
        creds = %{
          username: @username,
          password: generate_password(),
          provisioned_hash: nil,
          rotated_at: nil
        }

        case persist_credentials(state.table, creds) do
          :ok ->
            Logger.info("Storage settings: Samba password generated")

          {:error, reason} ->
            Logger.error(
              "Storage settings: password generated but NOT persisted: #{inspect(reason)}"
            )
        end

        {:reply, creds, state}
    end
  end

  def handle_call(:rotate_password, _from, state) do
    existing =
      case lookup_credentials(state.table) do
        {:ok, creds} -> creds
        :error -> %{username: @username, password: nil, provisioned_hash: nil, rotated_at: nil}
      end

    rotated = %{
      existing
      | password: generate_password(),
        provisioned_hash: nil,
        rotated_at: System.system_time(:second)
    }

    case persist_credentials(state.table, rotated) do
      :ok ->
        Logger.info("Storage settings: Samba password rotated")
        {:reply, rotated, state}

      {:error, reason} ->
        Logger.error("Storage settings: password rotation not persisted: #{inspect(reason)}")
        {:reply, rotated, state}
    end
  end

  def handle_call({:put_provisioned_hash, hash}, _from, state) do
    existing =
      case lookup_credentials(state.table) do
        {:ok, creds} -> creds
        :error -> %{username: @username, password: generate_password(), rotated_at: nil}
      end

    updated = Map.put(existing, :provisioned_hash, hash)

    with :ok <- :dets.insert(state.table, {@credentials_key, updated}),
         :ok <- :dets.sync(state.table) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        Logger.error("Storage settings: provisioned_hash write failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  # -- Private --

  defp lookup_drive(table, key) do
    case :dets.lookup(table, key) do
      [{_key, settings}] when is_map(settings) -> Map.merge(@drive_defaults, settings)
      _ -> @drive_defaults
    end
  end

  defp take_drive_fields(params) do
    Map.take(params, [:share_enabled?, :share_folder, :friendly_name, :last_seen_at])
  end

  defp lookup_credentials(table) do
    case :dets.lookup(table, @credentials_key) do
      [{@credentials_key, %{username: u, password: p} = creds}]
      when is_binary(u) and is_binary(p) ->
        {:ok,
         Map.merge(
           %{username: @username, password: nil, provisioned_hash: nil, rotated_at: nil},
           creds
         )}

      _ ->
        :error
    end
  end

  defp persist_credentials(table, creds) do
    with :ok <- :dets.insert(table, {@credentials_key, creds}),
         :ok <- :dets.sync(table) do
      :ok
    end
  end

  # 15 random bytes is 120 bits of entropy; Base32 (no padding) keeps the
  # result URL/shell-safe for the Security tab and smbpasswd stdin without
  # ambiguous characters.
  defp generate_password do
    :crypto.strong_rand_bytes(15) |> Base.encode32(padding: false)
  end

  defp dets_path do
    if File.dir?("/data") do
      "/data/storage_settings.dets"
    else
      Path.join([File.cwd!(), "_build", "storage_settings.dets"])
    end
  end
end
