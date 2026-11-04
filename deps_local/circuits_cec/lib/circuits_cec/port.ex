defmodule Circuits.CEC.Port do
  @moduledoc """
  Wire protocol of the `cec_port` helper, plus where to find it.

  The helper runs as an Erlang port with `{:packet, 2}`. Each frame is
  `<<tag::8, req_id::16, body::binary>>`. Requests carry a non-zero
  `req_id` that the reply echoes; unsolicited frames use `req_id` 0. Bodies
  are raw kernel structs (see `Circuits.CEC.Struct`) and native-endian
  scalars, which are little-endian on every supported target.

  This module only encodes and decodes frames. `Circuits.CEC.Transport.Port`
  owns the actual port.
  """

  alias Circuits.CEC.Errno

  @type req_id :: 1..0xFFFF

  @type request ::
          :caps
          | :g_phys
          | :g_log
          | {:s_log, binary()}
          | :g_mode
          | {:s_mode, non_neg_integer()}
          | {:transmit, binary()}
          | :g_conn

  @type frame ::
          {:reply, req_id(), {:ok, binary()} | {:error, Errno.t()}}
          | {:ready, caps :: binary()}
          | {:open_error, Errno.t()}
          | {:msg, binary()}
          | {:event, binary()}
          | :gone

  @req_caps 0x01
  @req_g_phys 0x02
  @req_g_log 0x03
  @req_s_log 0x04
  @req_g_mode 0x05
  @req_s_mode 0x06
  @req_transmit 0x07
  @req_g_conn 0x08

  @rsp_ok 0x80
  @rsp_err 0x81

  @evt_ready 0x90
  @evt_open_error 0x91
  @evt_msg 0x92
  @evt_event 0x93
  @evt_gone 0x94

  @log_addrs_size 92
  @msg_size 56
  @event_size 80
  @caps_size 76

  @doc """
  Path to the helper binary in this application's `priv/`.

  Only Linux builds have one; see `available?/0`.
  """
  @spec helper_path() :: Path.t()
  def helper_path, do: Application.app_dir(:circuits_cec, ["priv", "cec_port"])

  @doc "True if the helper was built (Linux targets only)."
  @spec available?() :: boolean()
  def available?, do: File.regular?(helper_path())

  @doc """
  Encodes a request frame (without the `{:packet, 2}` length, which the
  port adds).

  Raises `ArgumentError` for a struct body of the wrong size, so a bad
  struct never reaches the kernel.
  """
  @spec encode_request(req_id(), request()) :: binary()
  def encode_request(req_id, request) when is_integer(req_id) and req_id in 1..0xFFFF do
    {tag, body} = request_tag(request)
    <<tag, req_id::16, body::binary>>
  end

  defp request_tag(:caps), do: {@req_caps, <<>>}
  defp request_tag(:g_phys), do: {@req_g_phys, <<>>}
  defp request_tag(:g_log), do: {@req_g_log, <<>>}
  defp request_tag(:g_mode), do: {@req_g_mode, <<>>}
  defp request_tag(:g_conn), do: {@req_g_conn, <<>>}

  defp request_tag({:s_log, body}) when byte_size(body) == @log_addrs_size,
    do: {@req_s_log, body}

  defp request_tag({:s_mode, mode}) when is_integer(mode) and mode in 0..0xFFFFFFFF,
    do: {@req_s_mode, <<mode::little-32>>}

  defp request_tag({:transmit, body}) when byte_size(body) == @msg_size,
    do: {@req_transmit, body}

  defp request_tag(request),
    do: raise(ArgumentError, "invalid cec_port request: #{inspect(request)}")

  @doc """
  Decodes a frame from the helper.

  Bodies are checked against their struct size. Anything that doesn't
  parse is `{:error, :malformed}`.
  """
  @spec decode_frame(binary()) :: {:ok, frame()} | {:error, :malformed}
  def decode_frame(<<@rsp_ok, req_id::16, body::binary>>) when req_id != 0,
    do: {:ok, {:reply, req_id, {:ok, body}}}

  def decode_frame(<<@rsp_err, req_id::16, errno::little-32>>) when req_id != 0,
    do: {:ok, {:reply, req_id, {:error, Errno.to_atom(errno)}}}

  def decode_frame(<<@evt_ready, 0::16, caps::binary-size(@caps_size)>>),
    do: {:ok, {:ready, caps}}

  def decode_frame(<<@evt_open_error, 0::16, errno::little-32>>),
    do: {:ok, {:open_error, Errno.to_atom(errno)}}

  def decode_frame(<<@evt_msg, 0::16, msg::binary-size(@msg_size)>>), do: {:ok, {:msg, msg}}

  def decode_frame(<<@evt_event, 0::16, event::binary-size(@event_size)>>),
    do: {:ok, {:event, event}}

  def decode_frame(<<@evt_gone, 0::16>>), do: {:ok, :gone}
  def decode_frame(_frame), do: {:error, :malformed}
end
