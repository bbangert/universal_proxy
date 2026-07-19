defmodule UniversalProxy.BTD700.Transport do
  @moduledoc """
  Behaviour + default raw-file implementation for the BTD 700's hidraw
  control channel.

  Two semantics are load-bearing and not visible from the code below (see
  `research/beam-hidraw-io.md`):

    * **`:raw` fds are process-bound.** Only the process that called
      `open/1` may `read/2`/`write/2` it — a `Task` or any other process
      handed the same fd term will fail. This is why `DeviceWorker` opens
      its own writer fd and its linked reader child opens its own reader
      fd (dual-fd design; hidraw fans out input reports to every open fd
      on the node).
    * **A blocked `read/2` is released only by an incoming report or
      unplug.** There is no `O_NONBLOCK` path through `:file` (no fcntl),
      so a parked read cannot be interrupted from another process —
      `:file.close/1` from elsewhere is undocumented/unsafe as an
      interrupt mechanism. Unplug surfaces as `{:error, :enodev}` (treat
      `{:error, :eio}` the same); staleness must be detected by a
      *different* process (the owning `GenServer`'s wedge watchdog), which
      escalates to a USB re-authorize rather than ever touching this fd.

  Injectable into `DeviceWorker` (writer fd) and its reader loop (reader
  fd) so tests can substitute a fake, message-driven transport instead of
  a real `/dev/hidrawN` node.
  """

  @typedoc "Opaque file handle returned by `open/1`, passed back into `read/2`, `write/2`, `close/1`."
  @type fd :: File.io_device()

  @callback open(path :: String.t()) :: {:ok, fd()} | {:error, term()}
  @callback read(fd(), byte_count :: non_neg_integer()) ::
              {:ok, binary()} | :eof | {:error, term()}
  @callback write(fd(), packet :: binary()) :: :ok | {:error, term()}
  @callback close(fd()) :: :ok | {:error, term()}

  @doc "Open `path` (a hidraw device node) for both numbered-report read and write."
  @spec open(String.t()) :: {:ok, fd()} | {:error, term()}
  def open(path) when is_binary(path) do
    File.open(path, [:raw, :binary, :read, :write])
  end

  @doc """
  Blocking read of up to `byte_count` bytes — one hidraw read returns
  exactly one numbered input report (report-ID-prefixed), never a partial
  or coalesced frame. Blocks the calling process until a report arrives or
  the device is unplugged (`{:error, :enodev}`/`{:error, :eio}`).
  """
  @spec read(fd(), non_neg_integer()) :: {:ok, binary()} | :eof | {:error, term()}
  def read(fd, byte_count) do
    :file.read(fd, byte_count)
  end

  @doc "Write one already-framed 64-byte numbered output report."
  @spec write(fd(), binary()) :: :ok | {:error, term()}
  def write(fd, packet) when is_binary(packet) do
    :file.write(fd, packet)
  end

  @doc "Close a fd previously returned by `open/1`. Must be called from the owning process."
  @spec close(fd()) :: :ok | {:error, term()}
  def close(fd) do
    :file.close(fd)
  end
end
