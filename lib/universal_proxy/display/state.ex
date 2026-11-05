defmodule UniversalProxy.Display.State do
  @moduledoc """
  Owns the display's single viewport: starts it through the configured
  `UniversalProxy.Display.Renderer`, monitors it and remembers the screen
  (`UniversalProxy.Display.Spec`) to show on it.

  With `autostart: true` it shows a placeholder "Now Playing" screen at
  start, but only when the renderer is available and a DRM card exists
  (`<dri_dir>/card*`). The default is `autostart: false`: during the
  renderer benchmarks the viewport is started by hand
  (`UniversalProxy.Display.start_viewport/1`). A viewport that exits is not
  restarted yet.

  Options:

    * `:name` — registered name (default `#{inspect(__MODULE__)}`).
    * `:renderer` — the renderer module (default: the configured one).
    * `:autostart` — default: the configured value, else `false`.
    * `:viewport_supervisor` — the `DynamicSupervisor` the viewport runs under.
    * `:dri_dir` — where DRM cards appear (default `"/dev/dri"`).
    * `:viewport_opts` — default `start/2` options for the renderer, under
      any given to `start_viewport`. Default: the configured
      `:layer_cache_mb` and `:preferred_size`.
    * `:spec` — the first screen (default: `Spec.now_playing/1`).
  """

  use GenServer

  require Logger

  alias UniversalProxy.Display
  alias UniversalProxy.Display.Spec

  @type viewport :: %{handle: term(), ref: reference() | nil}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Whether `dri_dir` holds a DRM card node."
  @spec display_card?(Path.t()) :: boolean()
  def display_card?(dri_dir \\ "/dev/dri") do
    dri_dir |> Path.join("card*") |> Path.wildcard() |> Enum.any?()
  end

  @impl true
  def init(opts) do
    config = Display.config()

    state = %{
      renderer:
        Keyword.get(opts, :renderer, Keyword.get(config, :renderer, Display.Renderer.Null)),
      supervisor:
        Keyword.get(opts, :viewport_supervisor, Display.Supervisor.viewport_supervisor()),
      dri_dir: Keyword.get(opts, :dri_dir, "/dev/dri"),
      viewport_opts:
        Keyword.get_lazy(opts, :viewport_opts, fn ->
          config |> Keyword.take([:layer_cache_mb, :preferred_size]) |> drop_nil()
        end),
      spec: Keyword.get_lazy(opts, :spec, fn -> Spec.now_playing() end),
      viewport: nil
    }

    if Keyword.get(opts, :autostart, Keyword.get(config, :autostart, false)) do
      {:ok, state, {:continue, :autostart}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:autostart, state) do
    if state.renderer.available?() and display_card?(state.dri_dir) do
      case start_viewport(state, []) do
        {{:ok, _handle}, state} ->
          {:noreply, state}

        {{:error, reason}, state} ->
          Logger.warning("[Display] viewport did not start: #{inspect(reason)}")
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:start_viewport, opts}, _from, state) do
    {reply, state} = state |> stop_viewport() |> start_viewport(opts)
    {:reply, reply, state}
  end

  def handle_call(:stop_viewport, _from, state), do: {:reply, :ok, stop_viewport(state)}

  def handle_call(:viewport, _from, state), do: {:reply, viewport_handle(state), state}

  def handle_call(:status, _from, state) do
    status = %{
      running: true,
      renderer: state.renderer,
      available: state.renderer.available?(),
      display_card: display_card?(state.dri_dir),
      viewport: viewport_handle(state)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast({:show, spec}, state) do
    if state.viewport, do: state.renderer.push(state.viewport.handle, spec)
    {:noreply, %{state | spec: spec}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{viewport: %{ref: ref}} = state) do
    Logger.warning("[Display] viewport exited: #{inspect(reason)}")
    {:noreply, %{state | viewport: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_viewport(state, opts) do
    opts = state.viewport_opts |> Keyword.merge(opts) |> Keyword.put_new(:spec, state.spec)

    case state.renderer.start(state.supervisor, opts) do
      {:ok, handle} ->
        ref = if is_pid(handle), do: Process.monitor(handle)
        {{:ok, handle}, %{state | viewport: %{handle: handle, ref: ref}}}

      {:error, _reason} = error ->
        {error, state}
    end
  end

  defp stop_viewport(%{viewport: nil} = state), do: state

  defp stop_viewport(%{viewport: %{handle: handle, ref: ref}} = state) do
    if ref, do: Process.demonitor(ref, [:flush])
    :ok = state.renderer.stop(handle)
    %{state | viewport: nil}
  end

  defp viewport_handle(%{viewport: nil}), do: nil
  defp viewport_handle(%{viewport: %{handle: handle}}), do: handle

  defp drop_nil(opts), do: Enum.reject(opts, fn {_key, value} -> is_nil(value) end)
end
