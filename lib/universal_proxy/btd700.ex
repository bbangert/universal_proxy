defmodule UniversalProxy.BTD700 do
  @moduledoc """
  Public API boundary for the Sennheiser BTD 700 USB Bluetooth-audio dongle.

  The BTD 700 exposes a binary request/response protocol (`BTD700.Protocol`)
  over a numbered-report HID vendor collection on its hidraw control node —
  see that module's moduledoc for the wire format. This subtree drives that
  channel to reach configuration parity with the vendor app: audio mode,
  codec selection, dongle/LE/sink status, connect/disconnect, factory reset,
  and the full Auracast broadcast surface (state, name, encryption + key,
  quality). The audio half (snd-usb-audio ALSA card) is handled
  independently by `UniversalProxy.Audio`.

  ## Architecture

      BTD700                # this module — public boundary
      BTD700.Supervisor     # :one_for_all (WorkerSupervisor + Server)
        BTD700.WorkerSupervisor   # DynamicSupervisor, :one_for_one
        BTD700.Server             # orchestrator: inventory, hotplug, lifecycle
          BTD700.DeviceWorker     # one per device — owns the hidraw fds, serializes cmds
      BTD700.Protocol       # pure encode/decode (no side effects)
      BTD700.Hidraw         # control-node discovery (no tty exists)
      BTD700.Store          # DETS persistence, keyed {usb_port, vid, pid}

  All callers go through this module — never poke the worker, store,
  protocol, or hidraw discovery directly. Every device is addressed by its
  `{usb_port, vid, pid}` key (the same key as its audio output).

  ## Commands & state

  Set-commands complete on the device's `0xFF` ack (or a timeout) and
  return `:ok` / `{:error, reason}`. Ack bodies carry no parsed payload
  (`send_and_refresh/4` below re-queries so cached/broadcast state reflects
  the write). Preferences (`set_audio_mode/2`, `set_codec_mask/2`,
  `set_broadcast_info/2`, `set_broadcast_name/2`) are persisted in
  `BTD700.Store` and re-applied on the next (re)connect handshake. The
  Auracast broadcast key is **never persisted** — only sent, and only the
  `broadcast_encryption` boolean round-trips through `Store`.
  """

  import Bitwise

  alias UniversalProxy.BTD700.{DeviceWorker, Server, Store}

  @type key :: {String.t(), non_neg_integer() | nil, non_neg_integer() | nil}

  # Auracast name is clamped to 59 bytes on the wire (60-byte payload window
  # minus a trailing NUL — see `Protocol`'s `set_broadcast_name` gotcha);
  # reject an over-length name here with a clean error instead of letting it
  # silently truncate on the wire.
  @max_broadcast_name_bytes 59
  # The broadcast key has no NUL terminator, so its full 60-byte payload
  # window is usable.
  @max_broadcast_key_bytes 60

  # Read-only re-query set for a full refresh (`refresh/1`, and after
  # `factory_reset/1`). Mirrors `DeviceWorker`'s private `@handshake` list —
  # kept in sync by hand, same rationale as that module's
  # `@audio_mode_wire`/`@transport_wire` duplicated enum maps (there is no
  # public accessor for the handshake order, and duplicating a short list is
  # cheaper than exporting one for a single caller).
  @full_refresh ~w(
    get_firmware_version get_audio_mode get_supported_codecs get_codec_in_use
    get_dongle_state get_le_audio_state get_audio_quality get_broadcast_info
    get_broadcast_name get_sink_transport
  )a

  # -- Discovery / status --

  @doc "List attached BTD 700 devices."
  defdelegate list_devices, to: Server

  @doc "Fetch the cached protocol state for a device by its key."
  defdelegate get_state(key), to: Server

  @doc "Re-query every read-only handshake getter, refreshing the full cached state."
  @spec refresh(key()) :: :ok | {:error, term()}
  def refresh(key) do
    with_worker(key, fn pid ->
      Enum.each(@full_refresh, &DeviceWorker.refresh(pid, &1))
      :ok
    end)
  end

  # -- Audio mode / codecs --

  # Inverse of `Protocol`'s private `@audio_modes` decode map (mirrored here
  # for the same reason `DeviceWorker`'s `@audio_mode_wire` mirrors it: no
  # public atom->wire encoder exists — kept in sync by hand).
  @audio_mode_wire %{high_quality: 0, gaming: 1, broadcast: 2}

  # Inverse of `Protocol`'s private `@transport_modes` decode map (same
  # kept-in-sync-by-hand rationale as `@audio_mode_wire` above).
  @transport_wire %{disconnected: 0, classic: 1, le_audio: 2, multipoint: 3}

  @doc """
  Set the audio mode — `:high_quality` / `:gaming` / `:broadcast`.
  Persisted + re-applied on reconnect.

  The transport byte paired with the mode on the wire is **not** a stored
  preference (`Store` only ever persists `audio_mode`) — `0` is a real
  enum value (`:disconnected`), not a neutral placeholder, so it cannot be
  hardcoded. Instead it's resolved at send time from the worker's current
  cached `get_audio_mode` reading via a deferred 1-arity fun, reusing
  `DeviceWorker`'s own persisted-prefs re-apply mechanism
  (`resolve_args/2`) rather than a second divergent way of picking a
  transport byte.
  """
  @spec set_audio_mode(key(), :high_quality | :gaming | :broadcast) :: :ok | {:error, term()}
  def set_audio_mode(key, mode) do
    case Map.fetch(@audio_mode_wire, mode) do
      :error ->
        {:error, :invalid_mode}

      {:ok, mode_byte} ->
        Store.update_config(key, %{audio_mode: mode})

        with_worker(key, fn pid ->
          args = fn worker_state -> <<mode_byte, current_transport_wire(worker_state)>> end
          send_and_refresh(pid, :set_audio_mode, args, :get_audio_mode)
        end)
    end
  end

  # Falls back to 0 only when the handshake's audio_mode never decoded
  # (e.g. a `%{raw: _}` short-payload response) — mirrors
  # `DeviceWorker.current_transport_wire/1` exactly (private there too, so
  # duplicated rather than reached into).
  defp current_transport_wire(worker_state) do
    with %{transport: transport} <- Map.get(worker_state.state_cache, :audio_mode),
         {:ok, wire} <- Map.fetch(@transport_wire, transport) do
      wire
    else
      _ -> 0
    end
  end

  # Bit positions mirror `Protocol`'s private `@codec_bits` (decode
  # direction) — duplicated here for the same reason as `@audio_mode_wire`.
  @codec_bit_position %{
    sbc: 0,
    aptx: 1,
    aptx_adaptive: 2,
    aptx_lossless: 3,
    aptx_lite: 4,
    lc3: 5
  }

  @doc """
  Set the codec bitmask — a list of codec atoms
  (`:sbc`/`:aptx`/`:aptx_adaptive`/`:aptx_lossless`/`:aptx_lite`/`:lc3`).
  The wire has no single-codec selector, only a u16 LE mask. Persisted +
  re-applied.
  """
  @spec set_codec_mask(key(), [atom()]) :: :ok | {:error, term()}
  def set_codec_mask(key, codecs) when is_list(codecs) do
    mask = codecs_to_mask(codecs)

    persist_and_send(
      key,
      %{codec_mask: codecs},
      :set_codec_mask,
      <<mask::16-little>>,
      [:get_codec_in_use, :get_supported_codecs]
    )
  end

  defp codecs_to_mask(codecs) do
    Enum.reduce(codecs, 0, fn codec, acc ->
      case Map.fetch(@codec_bit_position, codec) do
        {:ok, bit} -> acc ||| 1 <<< bit
        :error -> acc
      end
    end)
  end

  # -- Connect / disconnect (trigger, not a preference) --

  @doc "Trigger a connect (`bt_connect` arg `<<1>>`). Not persisted — a trigger, not a pref."
  @spec connect(key()) :: :ok | {:error, term()}
  def connect(key),
    do: with_worker(key, &send_and_refresh(&1, :bt_connect, <<1>>, :get_dongle_state))

  @doc "Trigger a disconnect (`bt_connect` arg `<<0>>`). Not persisted."
  @spec disconnect(key()) :: :ok | {:error, term()}
  def disconnect(key),
    do: with_worker(key, &send_and_refresh(&1, :bt_connect, <<0>>, :get_dongle_state))

  # -- Auracast broadcast --

  @broadcast_state_wire %{off_private: 0, on_public: 1}
  @broadcast_quality_wire %{standard_16k: 0, standard_24k: 1, high: 2}

  @doc """
  Set the Auracast broadcast state/encryption/quality in one call (the wire
  command bundles all three: `<<state, encryption, quality>>`). Persisted +
  re-applied.

      set_broadcast_info(key, %{state: :on_public, encryption: true, quality: :high})
  """
  @spec set_broadcast_info(key(), %{
          state: :off_private | :on_public,
          encryption: boolean(),
          quality: :standard_16k | :standard_24k | :high
        }) :: :ok | {:error, term()}
  def set_broadcast_info(key, %{state: state_atom, encryption: encryption?, quality: quality_atom}) do
    with {:ok, state_byte} <- Map.fetch(@broadcast_state_wire, state_atom),
         {:ok, quality_byte} <- Map.fetch(@broadcast_quality_wire, quality_atom) do
      encryption_byte = if encryption?, do: 1, else: 0

      persist_and_send(
        key,
        %{
          broadcast_state: state_atom,
          broadcast_quality: quality_atom,
          broadcast_encryption: encryption?
        },
        :set_broadcast_info,
        <<state_byte, encryption_byte, quality_byte>>,
        :get_broadcast_info
      )
    else
      :error -> {:error, :invalid_broadcast_info}
    end
  end

  @doc """
  Set the Auracast broadcast name (UTF-8). Persisted + re-applied.
  Rejected at the boundary with `{:error, :name_too_long}` if it would not
  fit the wire's 59-byte (name + NUL) window — the device is never asked
  to silently truncate it.
  """
  @spec set_broadcast_name(key(), String.t()) :: :ok | {:error, :name_too_long} | {:error, term()}
  def set_broadcast_name(key, name) when is_binary(name) do
    if String.valid?(name) and byte_size(name) <= @max_broadcast_name_bytes do
      persist_and_send(
        key,
        %{broadcast_name: name},
        :set_broadcast_name,
        name,
        :get_broadcast_name
      )
    else
      {:error, :name_too_long}
    end
  end

  @doc """
  Set the Auracast broadcast encryption key/passphrase. **Send only — never
  persisted** (the dongle owns the key; `Store` only ever remembers the
  `broadcast_encryption` boolean, set via `set_broadcast_info/2`).
  """
  @spec set_broadcast_key(key(), binary()) :: :ok | {:error, term()}
  def set_broadcast_key(key, secret) when is_binary(secret) do
    if byte_size(secret) <= @max_broadcast_key_bytes do
      with_worker(key, &send_and_refresh(&1, :set_broadcast_key, secret, :get_broadcast_info))
    else
      {:error, :key_too_long}
    end
  end

  # -- Factory reset --

  @doc """
  Factory-reset the device. Send only (nothing to persist — the reset
  itself clears whatever the device had), then a full `refresh/1` since
  the reset changes device state wholesale, not just one field.
  """
  @spec factory_reset(key()) :: :ok | {:error, term()}
  def factory_reset(key) do
    with_worker(key, fn pid ->
      case DeviceWorker.command(pid, :factory_reset) do
        {:ok, _payload} ->
          Enum.each(@full_refresh, &DeviceWorker.refresh(pid, &1))
          :ok

        {:error, _reason} = error ->
          error
      end
    end)
  end

  # -- Private --

  # The worker pid is resolved once and passed to `fun`. If the worker dies
  # between resolution and the call, a blocking `command/3` surfaces the exit
  # and a fire-and-forget `refresh/2` cast is silently dropped — both
  # tolerated (the device re-broadcasts its state on the next handshake /
  # reconnect). A call *timeout* (worker wedged past DeviceWorker's own
  # command budget) comes back as `{:error, :timeout}` so LiveView callers
  # render an error instead of crashing or hanging.
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
  defp persist_and_send(key, params, cmd, args, refresh_cmds) do
    Store.update_config(key, params)
    with_worker(key, fn pid -> send_and_refresh(pid, cmd, args, refresh_cmds) end)
  end

  # A set-command's ack carries no parsed payload — `DeviceWorker.command/3`
  # only resolves `{:ok, %{}}` vs `{:error, reason}`. On success, re-query
  # `refresh_cmds` (one atom or a list) so the worker's state_cache (and
  # `"btd700:state"` broadcast) reflect the new value instead of the stale
  # pre-write one until the next handshake — surfaced during FMA120 HW
  # validation, same idiom here.
  defp send_and_refresh(pid, cmd, args, refresh_cmds) do
    case DeviceWorker.command(pid, cmd, args) do
      {:ok, _payload} ->
        refresh_cmds |> List.wrap() |> Enum.each(&DeviceWorker.refresh(pid, &1))
        :ok

      {:error, _reason} = error ->
        error
    end
  end
end
