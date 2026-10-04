defmodule UniversalProxyWeb.OpaqueKey do
  @moduledoc """
  Encodes and decodes the opaque device keys LiveViews put in `phx-value-*`
  attributes: URL-safe base64 of `:erlang.term_to_binary/1`.

  Decoding treats the param as untrusted input:

    * the decoded binary is capped at 256 bytes. The largest legitimate
      key is an ALSA long card name (at most 80 bytes) plus two small
      integers, about 110 bytes of ETF;
    * compressed ETF (`<<131, 80, ...>>`) is rejected before decoding, since
      `binary_to_term` would inflate it past the size cap first and
      `encode/1` never compresses;
    * `Plug.Crypto.non_executable_binary_to_term/2` with `[:safe]` refuses
      new atoms and any fun (Sobelow Misc.BinToTerm).

  Callers still assert the decoded shape themselves.
  """

  @max_bytes 256
  @etf_version 131
  @etf_compressed 80

  @doc "Encode a key term for use as an opaque LiveView param."
  @spec encode(term()) :: String.t()
  def encode(key), do: key |> :erlang.term_to_binary() |> Base.url_encode64(padding: false)

  @doc """
  Decode a param produced by `encode/1`. Returns `:error` for anything
  malformed, oversized, compressed or executable.
  """
  @spec decode(term()) :: {:ok, term()} | :error
  def decode(b64) when is_binary(b64) do
    with {:ok, bin} <- Base.url_decode64(b64, padding: false),
         true <- byte_size(bin) <= @max_bytes,
         <<@etf_version, tag, _::binary>> when tag != @etf_compressed <- bin do
      {:ok, Plug.Crypto.non_executable_binary_to_term(bin, [:safe])}
    else
      _ -> :error
    end
  rescue
    ArgumentError -> :error
  end

  def decode(_), do: :error
end
