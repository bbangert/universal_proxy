defmodule UniversalProxy.Display do
  @moduledoc """
  The TV UI on a Pi's HDMI output.

  The subsystem (`UniversalProxy.Display.Supervisor`) runs only where
  `config :universal_proxy, UniversalProxy.Display, enabled: true` (the Pi
  HDMI targets, config/target.exs). `UniversalProxy.Display.State` owns the
  single viewport, which a `UniversalProxy.Display.Renderer` draws
  `UniversalProxy.Display.Spec` screens on.

  ## The `:ui` switch

  `ui: true` turns the TV UI on: State follows the HDMI output's player,
  claims the TV remote's keys over CEC, starts the viewport by itself and
  Home Assistant gets the "TV display mode" select
  (`UniversalProxy.Display.Mode`). It goes on together with
  `UniversalProxy.Audio.DisplayRoles`' `enabled: true`, which gives the
  HDMI player the display roles the UI shows.

  With `ui: false` (the default everywhere until the TV UI ships) none of
  that happens: no keys are claimed, no select is advertised and the
  viewport only starts by hand, e.g. from IEx:

      UniversalProxy.Display.start_viewport(api: :raster)
      UniversalProxy.Display.show(UniversalProxy.Display.Spec.now_playing(title: "Hello"))
      UniversalProxy.Display.stop_viewport()

  These functions follow the `catch :exit` idiom for optional subsystems:
  while the subsystem is off or down they return a default instead of
  raising (and a wedged `State` reads as off, too).
  """

  alias UniversalProxy.Display.{Mode, Spec, State}

  @call_timeout 30_000
  # Past State's own bound on a play (15 s), which answers first.
  @play_call_timeout 20_000
  @topic "display:state"

  @doc "Whether config enables the display subsystem."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @doc "Whether config turns the TV UI on (see the moduledoc's `:ui` switch)."
  @spec ui?() :: boolean()
  def ui?, do: enabled?() and Keyword.get(config(), :ui, false)

  @doc "The `UniversalProxy.Display` application env."
  @spec config() :: keyword()
  def config, do: Application.get_env(:universal_proxy, __MODULE__, [])

  @doc """
  PubSub topic (on `UniversalProxy.PubSub`) carrying `{:display_mode, mode}`
  whenever the mode changes or a mode is set.
  """
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Sets the display mode, a `t:UniversalProxy.Display.Mode.t/0` or one of
  its option strings. Persisted on the HDMI output, so it survives a
  reboot; any mode but Off also wakes a blanked screen.

  `{:error, :invalid_mode}` for anything else, `{:error, :disabled}` while
  the UI is off and `{:error, :not_running}` while the subsystem is off or
  down.
  """
  @spec set_mode(Mode.t() | String.t()) ::
          :ok | {:error, :invalid_mode | :disabled | :not_running}
  def set_mode(mode_or_option) do
    case Mode.parse(mode_or_option) do
      {:ok, mode} -> GenServer.call(State, {:set_mode, mode})
      :error -> {:error, :invalid_mode}
    end
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "The current display mode, or `nil` while the UI is off or the subsystem down."
  @spec mode() :: Mode.t() | nil
  def mode do
    GenServer.call(State, :mode)
  catch
    :exit, _ -> nil
  end

  @doc """
  Starts the viewport by hand (stopping a running one first), while the UI
  is off. Options go to the renderer's `start/2`, over the configured
  defaults; see `UniversalProxy.Display.Renderer.Emerge` for its options.
  `{:error, :ui_active}` while the UI owns the viewport.
  """
  @spec start_viewport(keyword()) :: {:ok, term()} | {:error, term()}
  def start_viewport(opts \\ []) do
    GenServer.call(State, {:start_viewport, opts}, @call_timeout)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Stops a viewport started by hand, if one is running."
  @spec stop_viewport() :: :ok
  def stop_viewport do
    GenServer.call(State, :stop_viewport, @call_timeout)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Shows `spec` on the viewport, and on any viewport started later. With the
  UI on, the next UI change draws over it.
  """
  @spec show(Spec.t()) :: :ok
  def show(spec), do: GenServer.cast(State, {:show, spec})

  @doc "The running viewport's renderer handle, or `nil`."
  @spec viewport() :: term() | nil
  def viewport do
    GenServer.call(State, :viewport)
  catch
    :exit, _ -> nil
  end

  @doc """
  Plays MilkDrop preset `id` on the running visualizer session (see
  `UniversalProxy.MilkDrop.play/3`, which also validates `id` and saves a
  lock when nothing runs). `{:error, :not_presenting}` while no session
  runs or the subsystem is off or down; `{:error, :timeout}` when State
  does not answer in time.
  """
  @spec milkdrop_play(GenServer.server(), String.t(), boolean()) ::
          :ok | {:error, UniversalProxy.MilkDrop.play_error()}
  def milkdrop_play(server \\ State, id, lock?) when is_binary(id) and is_boolean(lock?) do
    GenServer.call(server, {:milkdrop_play, id, lock?}, @play_call_timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :not_presenting}
  end

  @doc """
  What the MilkDrop visualizer shows (see
  `UniversalProxy.MilkDrop.now_playing/1`); nothing while the subsystem is
  off or down.
  """
  @spec milkdrop_now_playing(GenServer.server()) :: State.now_playing()
  def milkdrop_now_playing(server \\ State) do
    GenServer.call(server, :milkdrop_now_playing)
  catch
    :exit, _ -> State.idle_now_playing()
  end

  @doc """
  A status map (mode, screen, playback, binding, viewport lifecycle, ...
  with the UI on), or `%{running: false}` while the subsystem is off.
  """
  @spec status() :: map()
  def status do
    GenServer.call(State, :status)
  catch
    :exit, _ -> %{running: false}
  end
end
