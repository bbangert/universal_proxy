defmodule UniversalProxy.Display do
  @moduledoc """
  The TV UI on a Pi's HDMI output.

  The subsystem (`UniversalProxy.Display.Supervisor`) runs only where
  `config :universal_proxy, UniversalProxy.Display, enabled: true` (the Pi
  HDMI targets, config/target.exs). `UniversalProxy.Display.State` owns the
  single viewport, which a `UniversalProxy.Display.Renderer` draws
  `UniversalProxy.Display.Spec` screens on.

  At this stage the viewport is started by hand (`autostart: false`), e.g.
  from IEx or `UniversalProxy.Display.Bench`:

      UniversalProxy.Display.start_viewport(api: :raster)
      UniversalProxy.Display.show(UniversalProxy.Display.Spec.now_playing(title: "Hello"))
      UniversalProxy.Display.stop_viewport()

  These functions follow the `catch :exit` idiom for optional subsystems:
  while the subsystem is off or down they return a default instead of
  raising (and a wedged `State` reads as off, too).
  """

  alias UniversalProxy.Display.Spec
  alias UniversalProxy.Display.State

  @call_timeout 30_000

  @doc "Whether config enables the display subsystem."
  @spec enabled?() :: boolean()
  def enabled?, do: Keyword.get(config(), :enabled, false)

  @doc "The `UniversalProxy.Display` application env."
  @spec config() :: keyword()
  def config, do: Application.get_env(:universal_proxy, __MODULE__, [])

  @doc """
  Starts the viewport (stopping a running one first). Options go to the
  renderer's `start/2`, over the configured defaults; see
  `UniversalProxy.Display.Renderer.Emerge` for its options.
  """
  @spec start_viewport(keyword()) :: {:ok, term()} | {:error, term()}
  def start_viewport(opts \\ []) do
    GenServer.call(State, {:start_viewport, opts}, @call_timeout)
  catch
    :exit, _ -> {:error, :not_running}
  end

  @doc "Stops the viewport, if one is running."
  @spec stop_viewport() :: :ok
  def stop_viewport do
    GenServer.call(State, :stop_viewport, @call_timeout)
  catch
    :exit, _ -> :ok
  end

  @doc "Shows `spec` on the viewport, and on any viewport started later."
  @spec show(Spec.t()) :: :ok
  def show(spec), do: GenServer.cast(State, {:show, spec})

  @doc "The running viewport's renderer handle, or `nil`."
  @spec viewport() :: term() | nil
  def viewport do
    GenServer.call(State, :viewport)
  catch
    :exit, _ -> nil
  end

  @doc "A status map, or `%{running: false}` while the subsystem is off."
  @spec status() :: map()
  def status do
    GenServer.call(State, :status)
  catch
    :exit, _ -> %{running: false}
  end
end
