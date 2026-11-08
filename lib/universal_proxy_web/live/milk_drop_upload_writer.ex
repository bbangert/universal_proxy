defmodule UniversalProxyWeb.MilkDropUploadWriter do
  @moduledoc """
  A `Phoenix.LiveView.UploadWriter` that streams one MilkDrop upload
  straight into `UniversalProxy.MilkDrop.UserPresets.incoming_dir/1`
  (`/data`) rather than Plug.Upload's temp dir (`/tmp`, a RAM tmpfs on the
  device).

  `init/1` reserves the entry's declared `:bytes` with
  `UserPresets.reserve/2` (from the upload channel process, which then
  owns the reservation) and writes to the path the server picked,
  created exclusively (`O_EXCL`, so not through a symlink) with mode
  0644. Writing past the reserved size fails the entry with
  `:too_large`, whatever the client sends. A cancelled or failed upload
  deletes its file and releases its reservation; a finished one nobody
  claims (`UserPresets.claim/2`, with `meta/1`'s `:ref`) is deleted by
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
        server = Keyword.get(opts, :server, UserPresets)
        bytes = Keyword.fetch!(opts, :bytes)

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
  end

  @impl true
  def meta(state), do: %{ref: state.ref, path: state.path}

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
        UserPresets.release(state.server, state.ref)
        {:error, {:io, reason}}
    end
  end

  def close(state, _cancel_or_error) do
    _ = :file.close(state.io)
    UserPresets.release(state.server, state.ref)
    {:ok, state}
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
