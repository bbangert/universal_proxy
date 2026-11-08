defmodule UniversalProxyWeb.MilkDropUploadWriter do
  @moduledoc """
  A `Phoenix.LiveView.UploadWriter` that streams one MilkDrop upload
  straight into `UniversalProxy.MilkDrop.UserPresets.incoming_dir/1`
  (`/data`) rather than Plug.Upload's temp dir (`/tmp`, a RAM tmpfs on the
  device).

  The file is `up-<random>.part` in `:dir`: a server-chosen name, never
  the client's, created exclusively (`O_EXCL`, so not through a symlink)
  with mode 0644. Writing past `:max_bytes` fails the entry with
  `:too_large`, whatever size the client declared. A cancelled or failed
  upload deletes its file.

  `claim/1` renames a finished upload to `up-<random>`, handing it to the
  consumer (`UserPresets.import/2` deletes it). A finished upload nobody
  claims stays `.part` until its upload channel exits (the LiveView went
  away, or the entry was removed after it finished; LiveView doesn't
  close the writer then): a watcher task under `:task_supervisor`
  (default `UniversalProxy.TaskSupervisor`) deletes it at that point.

  Options: `:dir` and `:max_bytes`, or `:refuse` — a reason `init/1`
  fails with, which the entry shows as `{:writer_failure, reason}`.
  """

  @behaviour Phoenix.LiveView.UploadWriter

  @prefix "up-"
  @part ".part"

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :refuse) do
      {:ok, reason} ->
        {:error, reason}

      :error ->
        open(
          Keyword.fetch!(opts, :dir),
          Keyword.fetch!(opts, :max_bytes),
          Keyword.get(opts, :task_supervisor, UniversalProxy.TaskSupervisor)
        )
    end
  end

  @impl true
  def meta(state), do: %{path: state.path}

  @impl true
  def write_chunk(data, %{bytes: bytes, max_bytes: max} = state)
      when bytes + byte_size(data) > max,
      do: {:error, :too_large, state}

  def write_chunk(data, state) do
    case :file.write(state.io, data) do
      :ok -> {:ok, %{state | bytes: state.bytes + byte_size(data)}}
      {:error, reason} -> {:error, {:io, reason}, state}
    end
  end

  @impl true
  def close(state, :done) do
    case :file.close(state.io) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        _ = File.rm(state.path)
        {:error, {:io, reason}}
    end
  end

  def close(state, _cancel_or_error) do
    _ = :file.close(state.io)
    _ = File.rm(state.path)
    {:ok, state}
  end

  @doc """
  Takes over the finished upload at `path` (a writer's `meta/1` path):
  renames it out of the watcher's reach and returns its new path.
  """
  @spec claim(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def claim(path) when is_binary(path) do
    base = Path.basename(path)

    if String.starts_with?(base, @prefix) and String.ends_with?(base, @part) do
      claimed = Path.join(Path.dirname(path), Path.basename(base, @part))

      case File.rename(path, claimed) do
        :ok -> {:ok, claimed}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_an_upload}
    end
  end

  defp open(dir, max_bytes, task_supervisor) do
    name = @prefix <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower) <> @part
    path = Path.join(dir, name)

    with {:ok, io} <- open_file(path) do
      case watch(task_supervisor, path) do
        :ok ->
          {:ok, %{path: path, io: io, bytes: 0, max_bytes: max_bytes}}

        {:error, _reason} = error ->
          _ = :file.close(io)
          _ = File.rm(path)
          error
      end
    end
  end

  defp open_file(path) do
    case :file.open(path, [:write, :exclusive, :binary, :raw]) do
      {:ok, io} ->
        case File.chmod(path, 0o644) do
          :ok ->
            {:ok, io}

          {:error, reason} ->
            _ = :file.close(io)
            _ = File.rm(path)
            {:error, {:io, reason}}
        end

      {:error, reason} ->
        {:error, {:io, reason}}
    end
  end

  # Runs in the upload channel process (init/1).
  defp watch(task_supervisor, path) do
    channel = self()

    case Task.Supervisor.start_child(task_supervisor, fn -> await_exit(channel, path) end) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, {:watcher, reason}}
    end
  catch
    :exit, reason -> {:error, {:watcher, reason}}
  end

  defp await_exit(channel, path) do
    ref = Process.monitor(channel)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> _ = File.rm(path)
    end
  end
end
