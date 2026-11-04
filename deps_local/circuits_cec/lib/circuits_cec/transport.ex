defmodule Circuits.CEC.Transport do
  @moduledoc """
  How an owner process talks to one `/dev/cecN`.

  A transport is a value held in the owner's state, not a process. The
  owner calls `open/2` and `send_request/2`, which never block, and feeds
  every mailbox message it doesn't recognise to `handle_message/2`, which
  turns the transport's own messages into `t:event/0`s (none, for
  bookkeeping messages such as a linked port's `:EXIT`).

  The first event after `open/2` is `{:ready, caps}` or
  `{:open_error, errno}`. Every request gets exactly one
  `{:reply, req_id, result}` unless the transport exits first. After
  `{:exit, status}` the transport is closed and further requests fail with
  `{:error, :closed}`. `{:error, :busy}` means every request id is in
  flight.

  Implementations: `Circuits.CEC.Transport.Port` (the `cec_port` helper)
  and `Circuits.CEC.Transport.Fake` (tests).
  """

  alias Circuits.CEC.{Errno, Port}

  @type t :: struct()

  @type event ::
          {:ready, caps :: binary()}
          | {:open_error, Errno.t()}
          | {:reply, Port.req_id(), {:ok, binary()} | {:error, Errno.t()}}
          | {:msg, binary()}
          | {:event, binary()}
          | :gone
          | {:exit, non_neg_integer() | term()}
          | {:protocol_error, binary()}

  @doc """
  Starts talking to `device` (e.g. `"/dev/cec0"`) on behalf of the calling
  process, which becomes the owner and receives the transport's messages.
  """
  @callback open(device :: Path.t(), opts :: keyword()) :: {:ok, t()} | {:error, term()}

  @doc "Sends a request. The reply arrives later as a `{:reply, req_id, _}` event."
  @callback send_request(t(), Port.request()) ::
              {:ok, Port.req_id(), t()} | {:error, :closed | :busy}

  @doc """
  Interprets a mailbox message. Returns `:unknown` for messages that don't
  belong to this transport.
  """
  @callback handle_message(t(), message :: term()) :: {:ok, [event()], t()} | :unknown

  @doc "Stops talking to the device. The helper exits when its stdin closes."
  @callback close(t()) :: :ok
end
