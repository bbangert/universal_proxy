defmodule UniversalProxy.FirmwareUpdate.Fwup do
  @moduledoc """
  Streams a `.fw` to `fwup --apply --framing --exit-handshake` via an
  Erlang Port.

  Library-shape: no host dependencies.

  ## Wire protocol

  Both directions are length-prefixed: `[4-byte BE length | payload]`.
  Input from us:

  - `[length | bytes]` records carrying `.fw` payload
  - `[0]` (zero-length record) marks end-of-stream

  Output from fwup (each record's payload begins with a 2-byte type
  code):

  - `PR` + 2-byte BE percent — progress
  - `OK` + 2 bytes reserved — success
  - `ER` + UTF-8 error message — error
  - `WN` + UTF-8 warning — non-fatal warning

  We deliberately do **not** pass `--exit-handshake`: in framing mode
  with an Erlang Port, the handshake byte deadlocks because fwup
  doesn't see EOF on stdin while the Port is alive. fwup exits
  cleanly on the zero-length terminator without the handshake.

  Source for the framing format: `nerves_firmware_http` and
  `ssh_subsystem_fwup` use the same parser. We rely on
  `Port.command/2`'s blocking semantics for back-pressure: when fwup's
  stdin buffer is full, the write blocks until fwup drains.

  ## Exit handshake

  `--exit-handshake` tells fwup not to close its stdout until the
  caller writes `Y` to its stdin. We send `Y` after the zero-length
  terminator so fwup gets a clean shutdown rather than a broken pipe.
  """

  @default_chunk_size 64 * 1024

  @type opt ::
          {:devpath, String.t() | nil}
          | {:task, String.t()}
          | {:progress, (term() -> any())}
          | {:chunk_size, pos_integer()}
          | {:fwup_path, String.t() | nil}

  @doc """
  Applies `fw_path` via `fwup`, blocking until fwup exits.

  ## Options

    * `:devpath` — block device to write to. Required for real
      hardware; for the host-side smoke test it can be a path to a
      file used as a target.
    * `:task` — the fwup task name (default `"upgrade"`).
    * `:progress` — callback invoked as `{:flashing, percent}` while
      fwup applies the firmware.
    * `:chunk_size` — read chunk size for `fw_path` (default
      #{@default_chunk_size}).
    * `:fwup_path` — explicit path to the fwup executable. Defaults to
      `System.find_executable("fwup")`.

  Returns `:ok` on exit status 0; `{:error, term()}` otherwise.
  """
  @spec apply(Path.t(), [opt]) :: :ok | {:error, term()}
  def apply(fw_path, opts \\ []) do
    fwup = Keyword.get(opts, :fwup_path) || System.find_executable("fwup")
    devpath = Keyword.get(opts, :devpath)
    task = Keyword.get(opts, :task, "upgrade")
    progress = Keyword.get(opts, :progress, fn _ -> :ok end)
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

    cond do
      is_nil(fwup) ->
        {:error, :fwup_executable_not_found}

      is_nil(devpath) ->
        {:error, :missing_devpath}

      not File.exists?(fw_path) ->
        {:error, {:firmware_not_found, fw_path}}

      true ->
        open_and_apply(fwup, fw_path, devpath, task, progress, chunk_size)
    end
  end

  defp open_and_apply(fwup, fw_path, devpath, task, progress, chunk_size) do
    port =
      Port.open({:spawn_executable, fwup}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["--apply", "--task", task, "--framing", "-d", devpath]
      ])

    try do
      with :ok <- stream_firmware(port, fw_path, chunk_size),
           :ok <- send_terminator(port),
           :ok <- await_exit(port, progress, <<>>) do
        :ok
      end
    after
      safe_close(port)
    end
  end

  defp stream_firmware(port, fw_path, chunk_size) do
    case File.open(fw_path, [:read, :binary]) do
      {:ok, fd} ->
        try do
          stream_loop(port, fd, chunk_size)
        after
          File.close(fd)
        end

      {:error, reason} ->
        {:error, {:firmware_open_failed, reason}}
    end
  end

  defp stream_loop(port, fd, chunk_size) do
    case IO.binread(fd, chunk_size) do
      :eof ->
        :ok

      {:error, reason} ->
        {:error, {:firmware_read_failed, reason}}

      data when is_binary(data) ->
        true = Port.command(port, <<byte_size(data)::32-big, data::binary>>)
        stream_loop(port, fd, chunk_size)
    end
  end

  defp send_terminator(port) do
    true = Port.command(port, <<0::32-big>>)
    :ok
  end

  defp await_exit(port, progress, buffer) do
    receive do
      {^port, {:data, chunk}} ->
        {new_buffer, events, last_error} = parse_frames(buffer <> chunk)

        Enum.each(events, fn
          {:progress, pct} -> progress.({:flashing, pct})
          # `WN` warnings are observable in stderr already; ignore here
          _ -> :ok
        end)

        await_exit(port, progress, new_buffer, last_error)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, n}} ->
        {:error, {:fwup_exit, n, buffer}}
    after
      30 * 60 * 1000 ->
        {:error, :fwup_timeout}
    end
  end

  defp await_exit(port, progress, buffer, last_error) do
    receive do
      {^port, {:data, chunk}} ->
        {new_buffer, events, new_error} = parse_frames(buffer <> chunk)

        Enum.each(events, fn
          {:progress, pct} -> progress.({:flashing, pct})
          _ -> :ok
        end)

        await_exit(port, progress, new_buffer, new_error || last_error)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, n}} ->
        {:error, {:fwup_exit, n, last_error}}
    after
      30 * 60 * 1000 ->
        {:error, :fwup_timeout}
    end
  end

  # Output framing: <<len::32-big, payload::binary-size(len)>> records.
  # Payload is 2-byte type + body. Returns {leftover, events, last_error}.
  defp parse_frames(buffer), do: parse_frames(buffer, [], nil)

  defp parse_frames(<<len::32-big, payload::binary-size(len), rest::binary>>, events, err) do
    {event, new_err} = decode_payload(payload, err)
    parse_frames(rest, [event | events], new_err)
  end

  defp parse_frames(leftover, events, err) do
    {leftover, Enum.reverse(events), err}
  end

  defp decode_payload(<<"PR", pct::16-big>>, err) when pct in 0..100, do: {{:progress, pct}, err}
  defp decode_payload(<<"OK", _rest::binary>>, err), do: {:ok, err}
  defp decode_payload(<<"ER", msg::binary>>, _err), do: {{:error_msg, msg}, msg}
  defp decode_payload(<<"WN", msg::binary>>, err), do: {{:warning, msg}, err}
  defp decode_payload(_other, err), do: {:unknown, err}

  defp safe_close(port) do
    try do
      Port.close(port)
    rescue
      ArgumentError -> :ok
    catch
      :error, :badarg -> :ok
    end
  end
end
