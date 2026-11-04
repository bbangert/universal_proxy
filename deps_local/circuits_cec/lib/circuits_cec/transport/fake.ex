defmodule Circuits.CEC.Transport.Fake do
  @moduledoc """
  In-memory `Circuits.CEC.Transport` for tests.

  A fake is a process started by the test. The code under test opens it as
  its transport with `open(device, fake: fake)`; the test then inspects
  what was requested and injects what the "kernel" sends back.

      {:ok, fake} = Circuits.CEC.Transport.Fake.start_link()
      # code under test: Fake.open("/dev/cec0", fake: fake)
      Fake.requests(fake)
      #=> [{1, :g_log}, {2, {:s_mode, 0x21}}]
      Fake.inject(fake, {:msg, Circuits.CEC.Struct.encode_msg(msg: <<0x04, 0x8F>>)})
      Fake.inject(fake, {:exit, 1})

  On open the fake sends `{:ready, caps}` with plausible vc4-like caps,
  unless `ready: :manual` (inject it yourself) or
  `ready: {:open_error, errno}`.

  Requests are answered by the `:responder` option, a function from the
  request to `{:ok, body}`, `{:error, errno}`, `:noreply` (answer later
  with `reply/3`) or `:default`. The default responder answers like an
  idle, unconfigured vc4 adapter: `s_log` and `transmit` echo their struct
  (transmit with a fresh `sequence`), `s_mode` succeeds, and the getters
  return the fake's current values.
  """

  @behaviour Circuits.CEC.Transport

  use GenServer

  alias Circuits.CEC.Struct

  @enforce_keys [:server, :ref]
  defstruct [:server, :ref, status: :open, next_id: 1]

  @type t :: %__MODULE__{
          server: GenServer.server(),
          ref: reference(),
          status: :open | :closed,
          next_id: pos_integer()
        }

  @type responder :: (Circuits.CEC.Port.request() ->
                        {:ok, binary()} | {:error, Circuits.CEC.Errno.t()} | :noreply | :default)

  ## Test-side API

  @doc """
  Starts a fake.

  Options: `:ready` (`:auto`, `:manual` or `{:open_error, errno}`),
  `:caps` (the caps struct sent in `ready`), `:responder`, and `:phys_addr`
  (what `g_phys` returns; default `0x1000`).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "Requests received so far, oldest first, as `{req_id, request}`."
  @spec requests(GenServer.server()) :: [{pos_integer(), Circuits.CEC.Port.request()}]
  def requests(fake), do: GenServer.call(fake, :requests)

  @doc "Sends a transport event to the owner, as if it came from the helper."
  @spec inject(GenServer.server(), Circuits.CEC.Transport.event()) :: :ok
  def inject(fake, event), do: GenServer.call(fake, {:inject, event})

  @doc "Answers a request that the responder left with `:noreply`."
  @spec reply(GenServer.server(), pos_integer(), {:ok, binary()} | {:error, term()}) :: :ok
  def reply(fake, req_id, result), do: inject(fake, {:reply, req_id, result})

  @doc "The process that opened the fake, or `nil`."
  @spec owner(GenServer.server()) :: pid() | nil
  def owner(fake), do: GenServer.call(fake, :owner)

  @doc "True once the owner called `close/1` or an `{:exit, _}` was injected."
  @spec closed?(GenServer.server()) :: boolean()
  def closed?(fake), do: GenServer.call(fake, :closed?)

  @doc "Replaces the responder."
  @spec set_responder(GenServer.server(), responder()) :: :ok
  def set_responder(fake, responder), do: GenServer.call(fake, {:set_responder, responder})

  ## Transport callbacks

  @impl Circuits.CEC.Transport
  def open(device, opts) do
    server = Keyword.fetch!(opts, :fake)
    ref = make_ref()

    case GenServer.call(server, {:open, self(), ref, device}) do
      :ok -> {:ok, %__MODULE__{server: server, ref: ref}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl Circuits.CEC.Transport
  def send_request(%__MODULE__{status: :closed}, _request), do: {:error, :closed}

  def send_request(%__MODULE__{} = t, request) do
    id = t.next_id
    :ok = GenServer.call(t.server, {:request, t.ref, id, request})
    {:ok, id, %{t | next_id: if(id == 0xFFFF, do: 1, else: id + 1)}}
  end

  @impl Circuits.CEC.Transport
  def handle_message(%__MODULE__{ref: ref} = t, {__MODULE__, ref, event}) do
    case event do
      {:exit, _} -> {:ok, [event], %{t | status: :closed}}
      _ -> {:ok, [event], t}
    end
  end

  def handle_message(%__MODULE__{}, _message), do: :unknown

  @impl Circuits.CEC.Transport
  def close(%__MODULE__{server: server, ref: ref}) do
    GenServer.call(server, {:close, ref})
  catch
    :exit, _ -> :ok
  end

  ## GenServer

  @impl GenServer
  def init(opts) do
    state = %{
      owner: nil,
      ref: nil,
      device: nil,
      closed?: false,
      requests: [],
      ready: Keyword.get(opts, :ready, :auto),
      caps: Keyword.get_lazy(opts, :caps, &default_caps/0),
      responder: Keyword.get(opts, :responder, fn _ -> :default end),
      phys_addr: Keyword.get(opts, :phys_addr, 0x1000),
      log_addrs: Struct.encode_log_addrs([]),
      mode: 0,
      sequence: 0
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:open, owner, ref, device}, _from, state) do
    state = %{state | owner: owner, ref: ref, device: device, closed?: false}

    case state.ready do
      :auto -> deliver(state, {:ready, state.caps})
      {:open_error, errno} -> deliver(state, {:open_error, errno})
      :manual -> :ok
    end

    {:reply, :ok, state}
  end

  def handle_call({:request, ref, id, request}, _from, %{ref: ref} = state) do
    state = %{state | requests: [{id, request} | state.requests]}

    {result, state} =
      case state.responder.(request) do
        :default -> default_response(request, state)
        other -> {other, state}
      end

    if result != :noreply, do: deliver(state, {:reply, id, result})
    {:reply, :ok, state}
  end

  # A request through a transport from an earlier open/2: drop it.
  def handle_call({:request, _ref, _id, _request}, _from, state), do: {:reply, :ok, state}

  def handle_call({:inject, event}, _from, state) do
    deliver(state, event)
    closed? = state.closed? or match?({:exit, _}, event)
    {:reply, :ok, %{state | closed?: closed?}}
  end

  def handle_call({:close, ref}, _from, %{ref: ref} = state),
    do: {:reply, :ok, %{state | closed?: true}}

  def handle_call({:close, _ref}, _from, state), do: {:reply, :ok, state}
  def handle_call(:requests, _from, state), do: {:reply, Enum.reverse(state.requests), state}
  def handle_call(:owner, _from, state), do: {:reply, state.owner, state}
  def handle_call(:closed?, _from, state), do: {:reply, state.closed?, state}

  def handle_call({:set_responder, fun}, _from, state),
    do: {:reply, :ok, %{state | responder: fun}}

  defp deliver(%{owner: nil}, _event), do: :ok
  defp deliver(%{owner: owner, ref: ref}, event), do: send(owner, {__MODULE__, ref, event})

  defp default_response(:caps, state), do: {{:ok, state.caps}, state}
  defp default_response(:g_phys, state), do: {{:ok, <<state.phys_addr::little-16>>}, state}
  defp default_response(:g_log, state), do: {{:ok, state.log_addrs}, state}
  defp default_response({:s_log, body}, state), do: {{:ok, body}, %{state | log_addrs: body}}
  defp default_response(:g_mode, state), do: {{:ok, <<state.mode::little-32>>}, state}
  defp default_response({:s_mode, mode}, state), do: {{:ok, <<>>}, %{state | mode: mode}}

  defp default_response(:g_conn, state),
    do: {{:ok, Struct.encode_connector_info(type: :drm, card_no: 0, connector_id: 32)}, state}

  defp default_response({:transmit, body}, state) do
    sequence = state.sequence + 1
    <<head::binary-24, _seq::little-32, rest::binary>> = body
    {{:ok, <<head::binary, sequence::little-32, rest::binary>>}, %{state | sequence: sequence}}
  end

  defp default_caps do
    Struct.encode_caps(
      driver: "vc4_hdmi",
      name: "vc4-hdmi",
      available_log_addrs: 1,
      capabilities: [:log_addrs, :transmit, :passthrough, :rc, :connector_info],
      version: 0x061200
    )
  end
end
