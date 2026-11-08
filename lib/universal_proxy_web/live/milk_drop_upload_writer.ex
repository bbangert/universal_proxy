defmodule UniversalProxyWeb.MilkDropUploadWriter do
  @moduledoc """
  A `Phoenix.LiveView.UploadWriter` that streams one MilkDrop upload
  straight into `UniversalProxy.MilkDrop.UserPresets.incoming_dir/1`
  (`/data`) rather than Plug.Upload's temp dir (`/tmp`, a RAM tmpfs on the
  device).

  `init/1` reserves the entry's declared `:bytes` with
  `UserPresets.reserve/3` (from the upload channel process, which then
  owns the reservation) and writes to the path the server picked,
  created exclusively (`O_EXCL`, so not through a symlink) with mode
  0644. Writing past the reserved size fails the entry with
  `:too_large`, whatever the client sends. A cancelled or failed upload
  deletes its file and releases its reservation. Each chunk first checks
  that the server that granted the reservation still runs: a restarted
  one has emptied `incoming/` and forgotten the reservation, so the entry
  fails with `:library_restarted` rather than keep writing an unlinked
  file. A finished one nobody
  claims (`UserPresets.claim/3`, with `meta/1`'s `:ref`) is deleted by
  the server when its channel exits — LiveView doesn't close the writer
  then.

  Options: `:bytes` and `:server` (default `UserPresets`), or `:refuse`
  — a reason `init/1` fails with, which the entry shows as
  `{:writer_failure, reason}`.
  """

  @behaviour Phoenix.LiveView.UploadWriter

  alias UniversalProxy.MilkDrop.UserPresets

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :refuse) do
      {:ok, reason} ->
        {:error, reason}

      :error ->
        # One pid for the reservation and the liveness check: a server
        # restarted in between can't pass for the one that granted it.
        case GenServer.whereis(Keyword.get(opts, :server, UserPresets)) do
          pid when is_pid(pid) -> reserve(pid, Keyword.fetch!(opts, :bytes))
          _none -> {:error, :not_running}
        end
    end
  end

  defp reserve(server, bytes) do
    with {:ok, %{ref: ref, path: path}} <- UserPresets.reserve(server, bytes) do
      case open_file(path) do
        {:ok, io} ->
          {:ok, %{server: server, ref: ref, path: path, io: io, bytes: 0, max_bytes: bytes}}

        {:error, _reason} = error ->
          UserPresets.release(server, ref)
          error
      end
    end
  end

  @impl true
  def meta(state), do: %{ref: state.ref, path: state.path}

  @impl true
  def write_chunk(data, %{bytes: bytes, max_bytes: max} = state)
      when bytes + byte_size(data) > max,
      do: {:error, :too_large, state}

  def write_chunk(data, state) do
    if granted?(state) do
      case :file.write(state.io, data) do
        :ok -> {:ok, %{state | bytes: state.bytes + byte_size(data)}}
        {:error, reason} -> {:error, {:io, reason}, state}
      end
    else
      {:error, :library_restarted, state}
    end
  end

  defp granted?(%{server: pid}), do: Process.alive?(pid)

  @impl true
  def close(state, :done) do
    case :file.close(state.io) do
      :ok ->
        {:ok, state}

      {:error, reason} ->
        discard(state)
        {:error, {:io, reason}}
    end
  end

  def close(state, _cancel_or_error) do
    _ = :file.close(state.io)
    discard(state)
    {:ok, state}
  end

  # The server deletes the file too, unless it is gone (stopped or
  # restarted) and no longer knows the reservation.
  defp discard(state) do
    _ = File.rm(state.path)
    UserPresets.release(state.server, state.ref)
  end

  defp open_file(path) do
    case :file.open(path, [:write, :exclusive, :binary, :raw]) do
      {:ok, io} ->
        case File.chmod(path, 0o644) do
          :ok ->
            {:ok, io}

          {:error, reason} ->
            _ = :file.close(io)
            {:error, {:io, reason}}
        end

      {:error, reason} ->
        {:error, {:io, reason}}
    end
  end
end
