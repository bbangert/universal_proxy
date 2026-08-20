defmodule UniversalProxy.StorageStub do
  @moduledoc """
  Stand-in for the `UniversalProxy.Storage` façade in LiveView tests.

  `OverviewLive` resolves the façade through
  `Application.get_env(:universal_proxy, :storage_facade, …)`, so pointing
  that at this module lets a test observe the drawer's calls and choose
  their replies.

  It exists because the real calls must not run in the suite: the format
  action shells out to `mkfs.ext4` against the device the subsystem
  resolves for the drive key it is handed, and eject `umount`s it. Reads (`state/0`) stay empty here — a
  LiveView test drives the row and drawer by broadcasting
  `{:storage_state, …}` on the real topic, exactly as the subsystem does.

  Every mutation sends `{:storage_call, name, args}` to the owner pid and
  replies with `Map.get(replies, name, default)`. A reply of
  `{:block, value}` instead sends `{:storage_blocked, name, caller_pid}`
  and waits for `:release` before answering `value`. Configure per test:

      StorageStub.install(self(), folders: %{"/" => ["backups"]})

  `install/2` also registers an `on_exit` that restores the real façade.

  Drive keys are the façade's `{slot_sub, vendor_id, product_id, serial}`
  4-tuple (or `nil`), and the recorded `{:storage_call, …}` args carry
  them verbatim — a test asserting on them is asserting on the identity
  the drawer resolved, serial included.
  """

  @default_credentials %{
    username: "backup",
    password: "test-only-password",
    provisioned_hash: nil,
    rotated_at: nil
  }

  @doc """
  Point `OverviewLive` at this stub for the duration of the test.

  Options: `:credentials`, `:supported?`, `:folders` (a
  `%{rel_path => [dir]}` map backing `list_folders/1`) and `:replies` (a
  `%{function_name => reply}` map overriding the defaults).
  """
  def install(owner, opts \\ []) do
    config = %{
      owner: owner,
      credentials: Keyword.get(opts, :credentials, @default_credentials),
      supported?: Keyword.get(opts, :supported?, true),
      folders: Keyword.get(opts, :folders, %{"/" => []}),
      replies: Keyword.get(opts, :replies, %{})
    }

    previous = Application.get_env(:universal_proxy, :storage_facade)
    Application.put_env(:universal_proxy, :storage_stub, config)
    Application.put_env(:universal_proxy, :storage_facade, __MODULE__)

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:universal_proxy, :storage_stub)

      case previous do
        nil -> Application.delete_env(:universal_proxy, :storage_facade)
        module -> Application.put_env(:universal_proxy, :storage_facade, module)
      end
    end)

    :ok
  end

  @doc "Replace the stub's configured replies mid-test."
  def put_replies(replies) do
    config = config()

    Application.put_env(:universal_proxy, :storage_stub, %{
      config
      | replies: Map.merge(config.replies, replies)
    })
  end

  # -- Façade surface --

  def topic, do: UniversalProxy.Storage.Server.topic()

  # The LiveView seeds from `state/0` on mount; tests push real drives in
  # afterwards over PubSub, so the seed is deliberately empty.
  def state,
    do: %{drives: [], mount: nil, share: :off, share_folder: "/", capacity: nil}

  def list_drives, do: state().drives

  def supported?, do: config().supported?

  def share_credentials, do: reply(:share_credentials, [], config().credentials)

  def rotate_password do
    credentials = config().credentials
    rotated = %{credentials | password: credentials.password <> "-rotated"}
    reply(:rotate_password, [], rotated)
  end

  def set_share_enabled(key, enabled?), do: reply(:set_share_enabled, [key, enabled?], :ok)

  def set_share_folder(key, path), do: reply(:set_share_folder, [key, path], :ok)

  # Takes the drive **key** (the serial-bearing 4-tuple), like
  # `format_drive/2`: only the mounted drive's key is accepted by the real
  # façade.
  def eject(drive_key), do: reply(:eject, [drive_key], :ok)

  # Takes the drive **key** (`nil` for a drive with no derivable bus path),
  # never a device path: `Storage.Server` resolves the device itself.
  def format_drive(drive_key, label \\ "USB_BACKUP"),
    do: reply(:format_drive, [drive_key, label], :ok)

  def list_folders(rel_path) do
    default =
      case Map.fetch(config().folders, rel_path) do
        {:ok, dirs} -> {:ok, dirs}
        :error -> {:error, :enoent}
      end

    reply(:list_folders, [rel_path], default)
  end

  def create_folder(rel_path, name) do
    default = {:ok, if(rel_path in ["/", ""], do: name, else: "#{rel_path}/#{name}")}
    reply(:create_folder, [rel_path, name], default)
  end

  # -- Private --

  defp reply(name, args, default) do
    config = config()
    send(config.owner, {:storage_call, name, args})

    case Map.get(config.replies, name, default) do
      # `{:block, value}` keeps the caller (a supervised task, for the
      # format) inside the façade call until the test releases it, so a
      # test can observe the LiveView while a long action is in flight.
      {:block, value} ->
        send(config.owner, {:storage_blocked, name, self()})

        receive do
          :release -> value
        after
          5_000 -> value
        end

      value ->
        value
    end
  end

  defp config, do: Application.fetch_env!(:universal_proxy, :storage_stub)
end
