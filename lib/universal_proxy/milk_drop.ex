defmodule UniversalProxy.MilkDrop do
  @moduledoc """
  The MilkDrop (projectM) visualizer: a TV display mode drawn by the
  `milkdrop_renderer` port binary from a self-hosted preset pack.

  Five pieces live here:

    * `UniversalProxy.MilkDrop.Store` — DETS settings (rotation interval,
      minimum frame rate, high-frequency presets, locked preset) and the
      runtime skip lists (per pack version, and for uploads);
    * `UniversalProxy.MilkDrop.Pack` — downloads, verifies and extracts the
      pinned preset pack into `root/0`;
    * `UniversalProxy.MilkDrop.UserPresets` — the library of uploaded
      presets and textures under `root/0`'s `user/`;
    * `UniversalProxy.MilkDrop.Index` — every pack and uploaded preset with
      its skip, selection and lock state, for the web UI's browser;
    * `UniversalProxy.Display.MilkDrop` — the renderer's Port owner, started
      by the display while the mode is active (not part of this subtree).

  `UniversalProxy.MilkDrop.Supervisor` runs UserPresets, Store, Pack and Index
  only when `enabled?/0`: a supported target
  (`#{inspect(~w(rpi3 rpi4 rpi5)a)}`, a compile-time constant) **and**
  `config :universal_proxy, UniversalProxy.Display, milkdrop: true`
  (config/target.exs sets it on the display targets). Host tests start
  the subtree with `enabled: true` instead.

  ## PubSub (`UniversalProxy.PubSub`)

    * `settings_topic/0` (`"milkdrop:settings"`) —
      `{:milkdrop_settings, settings}`,
      `{:milkdrop_skipped, version, %{preset => reason}}` and
      `{:milkdrop_store, :opened}` (the Store's table opened: re-read it);
    * `pack_topic/0` (`"milkdrop:pack"`) — `{:milkdrop_pack, status}` on
      every `UniversalProxy.MilkDrop.Pack` status change (including
      download progress), and `{:milkdrop_pack_started, status}` each time
      a Pack process starts;
    * `user_presets_topic/0` (`"milkdrop:user_presets"`) —
      `{:milkdrop_user_presets, change}` on every change to the upload
      library (see `UniversalProxy.MilkDrop.UserPresets`);
    * `selection_topic/0` (`"milkdrop:selection"`) —
      `{:milkdrop_selection, selection}`, the whole
      `UniversalProxy.MilkDrop.Store` selection record, on every change;
    * `UniversalProxy.MilkDrop.Index.topic/0` (`"milkdrop:index"`) —
      `{:milkdrop_index, change}` (see `UniversalProxy.MilkDrop.Index`);
    * `now_playing_topic/0` (`"milkdrop:now_playing"`) —
      `{:milkdrop_now_playing, now_playing}` (see `now_playing/1`)
      whenever it changes, from `UniversalProxy.Display.State`.

  ## Play now

  `play/3` shows one preset on the TV at once, optionally locking to it,
  through `UniversalProxy.Display.State` to the running renderer;
  `now_playing/1` reads what is on screen.
  """

  require Logger

  alias UniversalProxy.Display
  alias UniversalProxy.MilkDrop.Store

  @supported_targets ~w(rpi3 rpi4 rpi5)a

  # `Mix.target/0` is unavailable at runtime in a Nerves release, so the
  # predicate is baked in at compile time.
  @supported Mix.target() in @supported_targets

  @settings_topic "milkdrop:settings"
  @pack_topic "milkdrop:pack"
  @user_presets_topic "milkdrop:user_presets"
  @selection_topic "milkdrop:selection"
  @now_playing_topic "milkdrop:now_playing"

  # rpi3 presents on every second vblank (30 fps at 60 Hz); rpi4/rpi5 can
  # present at the refresh rate.
  @max_min_fps if(Mix.target() == :rpi3, do: 30, else: 60)
  @rpi3 Mix.target() == :rpi3

  @doc "Whether this build targets hardware the renderer supports (compile-time constant)."
  @spec supported?() :: boolean()
  def supported?, do: @supported

  @doc """
  Whether the MilkDrop subsystem should run: a supported target and the
  `UniversalProxy.Display` `:milkdrop` flag on (read at runtime). Always
  false on other targets; host tests start the subtree with
  `enabled: true` instead.
  """
  @spec enabled?() :: boolean()
  if @supported do
    def enabled?, do: Keyword.get(UniversalProxy.Display.config(), :milkdrop, false) == true
  else
    def enabled?, do: false
  end

  @doc """
  The highest minimum frame rate the user can pick on this board (the
  Store's `min_fps` runs from 20 to this in steps of 5): 30 on rpi3, 60
  elsewhere (a compile-time constant). Tests override it with `config
  :universal_proxy, :milkdrop_max_min_fps, n`.
  """
  @spec max_min_fps() :: pos_integer()
  def max_min_fps, do: Application.get_env(:universal_proxy, :milkdrop_max_min_fps, @max_min_fps)

  @doc """
  Whether the renderer follows the pack manifest's `rpi3` sweep hints
  (resolution rung, skip): its GLES2 build, on rpi3 (a compile-time
  constant). Tests override it with `config :universal_proxy,
  :milkdrop_rpi3_hints, boolean`.
  """
  @spec rpi3_hints?() :: boolean()
  def rpi3_hints?, do: Application.get_env(:universal_proxy, :milkdrop_rpi3_hints, @rpi3)

  @doc "PubSub topic for Store changes (see the moduledoc)."
  @spec settings_topic() :: String.t()
  def settings_topic, do: @settings_topic

  @doc "PubSub topic for Pack status changes (see the moduledoc)."
  @spec pack_topic() :: String.t()
  def pack_topic, do: @pack_topic

  @doc "PubSub topic for upload library changes (see the moduledoc)."
  @spec user_presets_topic() :: String.t()
  def user_presets_topic, do: @user_presets_topic

  @doc "PubSub topic for the Store's preset selection (see the moduledoc)."
  @spec selection_topic() :: String.t()
  def selection_topic, do: @selection_topic

  @doc "PubSub topic for what the TV shows (see the moduledoc)."
  @spec now_playing_topic() :: String.t()
  def now_playing_topic, do: @now_playing_topic

  @type play_error ::
          :invalid_id
          | :not_presenting
          | :timeout
          | :superseded
          | :unresponsive
          | {:refused,
             :unknown | :skipped | :high_frequency | :rpi3_skip | :load_failed | String.t()}

  @doc """
  Show preset `id` (a pack-relative file or a `user/` id) on the TV now,
  and with `lock?` hold rotation on it. Hidden and off-playlist presets
  can be played; the renderer refuses a skipped one, a `high_frequency`
  one while those are filtered out, an rpi3 `skip` one and one it does
  not know, or fails to load (`{:error, {:refused, reason}}`).

  `:ok` once it shows (within 15 s, else `{:error, :timeout}`);
  `{:error, :superseded}` when a newer `play/3` replaced it;
  `{:error, :unresponsive}` once the session's renderer stopped answering
  plays;
  `{:error, :not_presenting}` while no visualizer session runs (or ends
  meanwhile), in which case `lock?` still saves `id` as the Store's
  `locked`, so the next session starts on it (and a retiring session's
  late lock can't overwrite it: `Store.update/3`'s fence). A lock that
  does show is saved by the renderer's own `preset` event. Only the id's shape is
  checked here (`Store.valid_id?/1`, else `{:error, :invalid_id}`).

  Options: `:display` (the `UniversalProxy.Display.State` server) and
  `:store` (the Store).
  """
  @spec play(String.t(), boolean(), keyword()) :: :ok | {:error, play_error()}
  def play(id, lock? \\ false, opts \\ []) when is_boolean(lock?) do
    if Store.valid_id?(id) do
      # Taken first: every renderer session that could still write a lock
      # when nothing presents started before it.
      fence = System.unique_integer([:monotonic])

      case Display.milkdrop_play(Keyword.get(opts, :display, Display.State), id, lock?) do
        {:error, :not_presenting} = error when lock? ->
          save_lock(Keyword.get(opts, :store, Store), id, fence)
          error

        reply ->
          reply
      end
    else
      {:error, :invalid_id}
    end
  end

  @doc """
  Release the lock: a running visualizer session resumes rotation at
  once, and the Store's `locked` is cleared so the next session starts
  unlocked. Idempotent. Returns the Store's answer (`{:error, reason}`
  when it can't write). Options: `:display` and `:store`, as for
  `play/3`.

  With no session presenting the clear raises `Store.update/3`'s fence,
  as `play/3`'s saved lock does, so a retiring session's late lock can't
  bring it back. With one presenting it doesn't: that session's own
  later locks (a remote's lock key) must still count, and its `preset`
  event for the unlock saves `nil` too.
  """
  @spec unlock(keyword()) :: :ok | {:error, term()}
  def unlock(opts \\ []) do
    # Taken first, as in play/3.
    fence = System.unique_integer([:monotonic])

    update_opts =
      case Display.milkdrop_unlock(Keyword.get(opts, :display, Display.State)) do
        :ok -> []
        {:error, :not_presenting} -> [fence: fence]
      end

    case Store.update(Keyword.get(opts, :store, Store), %{locked: nil}, update_opts) do
      {:ok, _settings} -> :ok
      error -> error
    end
  end

  defp save_lock(store, id, fence) do
    with {:error, reason} <- Store.update(store, %{locked: id}, fence: fence) do
      Logger.warning("MilkDrop: could not save the lock on #{inspect(id)}: #{inspect(reason)}")
    end
  end

  @doc """
  What the TV shows, also broadcast on `now_playing_topic/0`:

      %{preset: id | nil, locked: boolean(),
        selection: %{gen:, eligible:, playlist_fallback:, hidden_fallback:} | nil}

  `preset` is `nil` unless a visualizer session is presenting. `selection`
  is the renderer's last answer to the selection it was given: how many
  presets the rotation can pick from, and whether the playlist
  (`playlist_fallback`) or the hidden list (`hidden_fallback`) left
  nothing eligible, so the renderer ignores it. Option `:display` names
  the `UniversalProxy.Display.State` server.
  """
  @spec now_playing(keyword()) :: Display.State.now_playing()
  def now_playing(opts \\ []),
    do: Display.milkdrop_now_playing(Keyword.get(opts, :display, Display.State))

  @doc """
  Directory holding the extracted pack(s), download temporaries, the
  uploads (`user/`, `incoming/`) and the Store's DETS file: `/data/milkdrop` on Nerves, `_build/milkdrop` on the
  host.
  """
  @spec root() :: String.t()
  def root do
    if File.dir?("/data") do
      "/data/milkdrop"
    else
      Path.join([File.cwd!(), "_build", "milkdrop"])
    end
  end
end
