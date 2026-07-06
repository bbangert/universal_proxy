defmodule UniversalProxy.FMA120 do
  @moduledoc """
  Public API boundary for the FlooGoo FMA120 USB Bluetooth-audio dongle.

  The FMA120 exposes a [FlooCast](https://github.com/Flairmesh/FlooCast)
  ASCII-over-serial control channel on its CDC-ACM node (`/dev/ttyACM*`).
  This subtree drives that channel to reach configuration parity with the
  vendor's PC app: firmware/codec/RSSI status, pairing & connection
  management, codec/feature/LE-audio preferences, and Auracast broadcast
  configuration. The audio half (snd-usb-audio ALSA card) is handled
  independently by `UniversalProxy.Audio`.

  ## Architecture

      FMA120                # this module — public boundary
      FMA120.Supervisor     # :one_for_all (WorkerSupervisor + Server)
        FMA120.WorkerSupervisor   # DynamicSupervisor, :one_for_one
        FMA120.Server             # orchestrator: inventory, hotplug, lifecycle
          FMA120.DeviceWorker     # one per device — owns Circuits.UART, serializes cmds
      FMA120.Protocol       # pure encode/decode (no side effects)
      FMA120.Store          # DETS persistence, keyed {usb_port, vid, pid}

  All callers go through this module — never poke the worker, store, or
  protocol directly. Every device is addressed by its `{usb_port, vid, pid}`
  key (the same key as its audio output).

  ## Commands & state

  Set-commands block on the device's `OK`/`ER` (or a timeout) and return
  `:ok` / `{:error, reason}`. Where a command changes derived state
  (connect/disconnect), the worker re-queries the relevant headers and
  re-broadcasts on `"fma120:state"`. Preferences (`set_le_preference/2`,
  `set_features/2`, `set_audio_mode/2`, broadcast config) are persisted in
  `FMA120.Store` and re-applied on the next (re)connect handshake.
  """

  alias UniversalProxy.FMA120.{DeviceWorker, Server, Store}

  @type key :: {String.t(), non_neg_integer() | nil, non_neg_integer() | nil}

  # -- Discovery / status (Approach A) --

  @doc "List attached FMA120 devices."
  defdelegate list_devices, to: Server

  @doc "Fetch the cached protocol state for a device by its key."
  defdelegate get_state(key), to: Server

  # -- Phase 5: connection & discovery --

  @doc "Start an inquiry/scan for nearby Bluetooth devices (`IQ`)."
  @spec inquiry(key()) :: :ok | {:error, term()}
  def inquiry(key), do: with_worker(key, &DeviceWorker.command(&1, "IQ", ""))

  @doc "Set whether the dongle is discoverable as a sink (`MD` 00/01)."
  @spec set_discoverable(key(), boolean()) :: :ok | {:error, term()}
  def set_discoverable(key, on?) when is_boolean(on?) do
    with_worker(key, fn pid ->
      DeviceWorker.command(pid, "MD", if(on?, do: 0x01, else: 0x00))
    end)
  end

  @doc """
  Toggle the connection to a paired device by index (`TC`). This is the
  primary connect/disconnect the vendor GUI uses; afterwards `FN`/`ST`/`AC`
  are re-queried to refresh state.
  """
  @spec connect(key(), 0..255) :: :ok | {:error, term()}
  def connect(key, index) when index in 0..255 do
    with_worker(key, fn pid ->
      result = DeviceWorker.command(pid, "TC", index)
      DeviceWorker.refresh(pid, ["FN", "ST", "AC"])
      result
    end)
  end

  @doc "Explicit disconnect (`DC`), then refresh `ST`/`AC`."
  @spec disconnect(key()) :: :ok | {:error, term()}
  def disconnect(key) do
    with_worker(key, fn pid ->
      result = DeviceWorker.command(pid, "DC", "")
      DeviceWorker.refresh(pid, ["FN", "ST", "AC"])
      result
    end)
  end

  @doc "Clear all paired devices (`CP` with no payload), then refresh the list."
  @spec clear_paired(key()) :: :ok | {:error, term()}
  def clear_paired(key) do
    with_worker(key, fn pid ->
      result = DeviceWorker.command(pid, "CP", "")
      DeviceWorker.refresh(pid, ["FN"])
      result
    end)
  end

  @doc "Clear one paired device by index (`CP` <index>), then refresh the list."
  @spec clear_paired(key(), 0..255) :: :ok | {:error, term()}
  def clear_paired(key, index) when index in 0..255 do
    with_worker(key, fn pid ->
      result = DeviceWorker.command(pid, "CP", index)
      DeviceWorker.refresh(pid, ["FN"])
      result
    end)
  end

  # -- Phase 6: codec / feature / LE-audio preferences --

  @doc "Set the feature-flag bitmask (`FT`). Persisted + re-applied on reconnect."
  @spec set_features(key(), 0..255) :: :ok | {:error, term()}
  def set_features(key, bitmask) when bitmask in 0..255 do
    persist_and_send(key, %{feature_flags: bitmask}, "FT", bitmask)
  end

  @doc "Set the LE-audio preference (`LF`: `:a2dp`/`:lea`). Persisted + re-applied."
  @spec set_le_preference(key(), :a2dp | :lea) :: :ok | {:error, term()}
  def set_le_preference(key, :a2dp),
    do: persist_and_send(key, %{le_preference: :a2dp}, "LF", 0x00)

  def set_le_preference(key, :lea), do: persist_and_send(key, %{le_preference: :lea}, "LF", 0x01)

  @doc """
  Set the audio mode (`AM`) — `:high_quality` / `:gaming` / `:broadcast`.
  Switching to/from `:broadcast` is the 1:1-vs-Auracast switch.
  """
  @spec set_audio_mode(key(), :high_quality | :gaming | :broadcast) :: :ok | {:error, term()}
  def set_audio_mode(key, mode) do
    case audio_mode_byte(mode) do
      nil -> {:error, :invalid_mode}
      byte -> with_worker(key, fn pid -> send_and_refresh(pid, "AM", byte) end)
    end
  end

  # -- Phase 7: Auracast / broadcast --

  @doc "Set the broadcast (Auracast) mode bitfield (`BM`). Persisted + re-applied."
  @spec set_broadcast_mode(key(), 0..255) :: :ok | {:error, term()}
  def set_broadcast_mode(key, byte) when byte in 0..255 do
    persist_and_send(key, %{broadcast_mode: byte}, "BM", byte)
  end

  @doc "Set the Auracast broadcast name (`BN`, UTF-8). Persisted + re-applied."
  @spec set_broadcast_name(key(), String.t()) :: :ok | {:error, term()}
  def set_broadcast_name(key, name) when is_binary(name) do
    persist_and_send(key, %{broadcast_name: name}, "BN", name)
  end

  @doc "Set the broadcast address (`AD`, 48-bit binary)."
  @spec set_broadcast_address(key(), <<_::48>>) :: :ok | {:error, term()}
  def set_broadcast_address(key, <<_::48>> = addr) do
    with_worker(key, &DeviceWorker.command(&1, "AD", Base.encode16(addr)))
  end

  @doc """
  Set the Auracast encryption passphrase (`BE`, ≤16 chars). The device reports
  back set/unset; only that boolean is persisted (never the passphrase).
  """
  @spec set_broadcast_encryption(key(), String.t()) :: :ok | {:error, term()}
  def set_broadcast_encryption(key, passphrase)
      when is_binary(passphrase) and byte_size(passphrase) <= 16 do
    with_worker(key, fn pid ->
      result = DeviceWorker.command(pid, "BE", passphrase)

      if result == :ok do
        Store.update_config(key, %{broadcast_encryption_set: passphrase != ""})
        DeviceWorker.refresh(pid, ["BE"])
      end

      result
    end)
  end

  # -- Private --

  # The worker pid is resolved once and passed to `fun`. If the worker dies
  # between resolution and the call, a blocking `command/3` surfaces the exit
  # and a fire-and-forget `refresh/2` cast is silently dropped — both tolerated
  # (the device re-broadcasts its state on the next handshake / reconnect).
  # A call *timeout* (worker wedged past DeviceWorker's own command budget)
  # comes back as `{:error, :timeout}` so LiveView callers render an error
  # instead of crashing or hanging.
  defp with_worker(key, fun) do
    case Server.worker_for(key) do
      {:ok, pid} -> call_worker(pid, fun)
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # Public (`@doc false`) so the timeout conversion is unit-testable.
  # The second clause covers a worker that stops (or is already dead)
  # while the call is pending — e.g. the wedge-recovery
  # `{:stop, :wedged_recovered, _}` — which re-raises in the caller with
  # the stop reason, not `:timeout`. Only call-shaped exits are caught;
  # anything else propagates.
  @doc false
  def call_worker(pid, fun) do
    fun.(pid)
  catch
    :exit, {:timeout, {GenServer, :call, _}} -> {:error, :timeout}
    :exit, {_reason, {GenServer, :call, _}} -> {:error, :unavailable}
  end

  # Persist the preference first (so it survives a reconnect even if the live
  # write below fails or the device is mid-handshake), then send it and
  # re-query so the cached/broadcast state reflects the new value.
  defp persist_and_send(key, params, header, payload) do
    Store.update_config(key, params)
    with_worker(key, fn pid -> send_and_refresh(pid, header, payload) end)
  end

  # A set-command does not echo its new value — the device only replies OK/ER.
  # So on success re-query the same header to refresh the worker's state_cache
  # (and re-broadcast on "fma120:state"); otherwise the UI would show the stale
  # pre-write value until the next handshake. Surfaced during HW validation.
  defp send_and_refresh(pid, header, payload) do
    result = DeviceWorker.command(pid, header, payload)
    if result == :ok, do: DeviceWorker.refresh(pid, [header])
    result
  end

  defp audio_mode_byte(:high_quality), do: 0x00
  defp audio_mode_byte(:gaming), do: 0x01
  defp audio_mode_byte(:broadcast), do: 0x02
  defp audio_mode_byte(_), do: nil
end
