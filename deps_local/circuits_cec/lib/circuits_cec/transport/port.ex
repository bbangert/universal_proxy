defmodule Circuits.CEC.Transport.Port do
  @moduledoc """
  `Circuits.CEC.Transport` over the `cec_port` helper.

  The calling process owns the Erlang port (and is linked to it). Closing
  the port, or the owner dying, closes the helper's stdin and the helper
  exits; the kernel then drops our follower and initiator roles but keeps
  the logical-address claim, which is adapter state.

  Options for `open/2`:

    * `:helper` - path to the helper binary (default:
      `Circuits.CEC.Port.helper_path/0`)

  `open/2` returns `{:error, :unsupported}` when there is no helper, which
  is the case on non-Linux hosts.
  """

  @behaviour Circuits.CEC.Transport

  alias Circuits.CEC.Port, as: Protocol

  defstruct [:port, :device, status: :open, next_id: 1, pending: MapSet.new()]

  @type t :: %__MODULE__{
          port: port(),
          device: Path.t(),
          status: :open | :closed,
          next_id: Protocol.req_id(),
          pending: MapSet.t(Protocol.req_id())
        }

  @max_req_id 0xFFFF

  @impl Circuits.CEC.Transport
  def open(device, opts \\ []) when is_binary(device) do
    helper = Keyword.get(opts, :helper, Protocol.helper_path())

    if File.regular?(helper) do
      port =
        Port.open({:spawn_executable, helper}, [
          {:args, [device]},
          {:packet, 2},
          :binary,
          :exit_status,
          :use_stdio
        ])

      {:ok, %__MODULE__{port: port, device: device}}
    else
      {:error, :unsupported}
    end
  rescue
    e in ErlangError -> {:error, e.original}
  end

  @impl Circuits.CEC.Transport
  def send_request(%__MODULE__{status: :closed}, _request), do: {:error, :closed}

  def send_request(%__MODULE__{} = t, request) do
    if MapSet.size(t.pending) >= @max_req_id do
      {:error, :busy}
    else
      id = free_id(t.next_id, t.pending)
      frame = Protocol.encode_request(id, request)

      try do
        true = Port.command(t.port, frame)
        {:ok, id, %{t | next_id: next_id(id), pending: MapSet.put(t.pending, id)}}
      rescue
        ArgumentError -> {:error, :closed}
      end
    end
  end

  @impl Circuits.CEC.Transport
  def handle_message(%__MODULE__{port: port, status: :open} = t, {port, {:data, data}}) do
    case Protocol.decode_frame(data) do
      {:ok, {:reply, id, _result} = reply} ->
        if MapSet.member?(t.pending, id) do
          {:ok, [reply], %{t | pending: MapSet.delete(t.pending, id)}}
        else
          {:ok, [{:protocol_error, data}], t}
        end

      {:ok, frame} ->
        {:ok, [frame], t}

      {:error, :malformed} ->
        {:ok, [{:protocol_error, data}], t}
    end
  end

  def handle_message(%__MODULE__{port: port, status: :open} = t, {port, {:exit_status, status}}) do
    {:ok, [{:exit, status}], closed(t)}
  end

  # A trapping owner also gets the link's :EXIT. After :exit_status it is
  # bookkeeping; without one the port itself failed.
  def handle_message(%__MODULE__{port: port} = t, {:EXIT, port, reason}) do
    case t.status do
      :open -> {:ok, [{:exit, reason}], closed(t)}
      :closed -> {:ok, [], t}
    end
  end

  def handle_message(%__MODULE__{port: port, status: :closed} = t, {port, _message}),
    do: {:ok, [], t}

  def handle_message(%__MODULE__{}, _message), do: :unknown

  @impl Circuits.CEC.Transport
  def close(%__MODULE__{status: :closed}), do: :ok

  def close(%__MODULE__{port: port}) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp closed(t), do: %{t | status: :closed, pending: MapSet.new()}

  defp free_id(id, pending) do
    if MapSet.member?(pending, id), do: free_id(next_id(id), pending), else: id
  end

  defp next_id(@max_req_id), do: 1
  defp next_id(id), do: id + 1
end
