defmodule UniversalProxy.Sendspin.CPace do
  @moduledoc """
  CPACE-X25519-SHA512 — a balanced PAKE — per draft-irtf-cfrg-cpace-21.

  Both parties start from a shared low-entropy secret (`PRS`, a PIN for
  Sendspin) and exchange one public share each. They agree on the same
  intermediate session key (`ISK`) if and only if the PRS, channel
  identifier (`CI`), session identifier (`sid`) and both associated-data
  fields matched.

  This module is *generic* CPace: no Sendspin labels, no PIN derivation, no
  message confirmation. `UniversalProxy.Sendspin.Pairing` layers those on
  top. Both roles are implemented — party A (initiator) and party B
  (responder) — because the pairing tests script an MA-side party A.

  ## Usage

      {:ok, b} = CPace.start(:b, prs: "483106", sid: sid, ad: "client")
      # → send CPace.public_share(b) to the peer, receive Ya
      {:ok, isk} = CPace.finish(b, ya, "server")

  `start/2` and `finish/3` return `:error` rather than raising when the
  group operation lands on the neutral element (draft Section 7.2: "MUST
  abort if K = G.I"). Callers must treat that as a failed pairing, not a
  retryable condition.

  ## Suite parameters (draft Section 5, Section 8.2)

  Group `G_X25519` (`DSI = "CPace255"`, 32-byte field) with SHA-512
  (64-byte output, 128-byte input block). `scalar_mult` and
  `scalar_mult_vfy` are both plain `X25519`, whose validity check is
  "output is not all-zero".

  ## Transcript modes

  Sendspin runs CPace with clear initiator/responder roles, so the default
  transcript is `transcript_ir` (draft Section 6.3). The symmetric
  `transcript_oc` form is implemented too and selectable with
  `transcript: :oc`; the draft mandates it whenever message ordering is not
  enforced by the protocol flow.
  """

  import Bitwise

  alias UniversalProxy.Sendspin.CPace.Field

  @dsi "CPace255"
  @isk_dsi @dsi <> "_ISK"

  @hash :sha512
  # H.s_in_bytes for SHA-512 (draft Section 6.2).
  @hash_block_bytes 128

  @field_size_bytes 32

  # G.I, the neutral element (draft Section 8.2).
  @neutral_element :binary.copy(<<0>>, @field_size_bytes)

  @type role :: :a | :b
  @type transcript_mode :: :ir | :oc

  @type t :: %__MODULE__{
          role: role(),
          sid: binary(),
          ad: binary(),
          scalar: binary(),
          share: binary(),
          transcript: transcript_mode()
        }

  @enforce_keys [:role, :sid, :ad, :scalar, :share, :transcript]
  defstruct [:role, :sid, :ad, :scalar, :share, :transcript]

  # -- Protocol --

  @doc """
  Begin a CPace run as `:a` (initiator) or `:b` (responder).

  Options:

    * `:prs` (required) — the shared secret octet string.
    * `:ci` — channel identifier, default `""`.
    * `:sid` — session identifier, default `""`.
    * `:ad` — this party's associated data, default `""`.
    * `:transcript` — `:ir` (default) or `:oc`.
    * `:scalar` — 32 raw bytes, for test vectors only. Omit in production
      so the scalar is freshly sampled.
  """
  @spec start(role(), keyword()) :: {:ok, t()} | :error
  def start(role, opts) when role in [:a, :b] do
    prs = Keyword.fetch!(opts, :prs)
    ci = Keyword.get(opts, :ci, "")
    sid = Keyword.get(opts, :sid, "")
    ad = Keyword.get(opts, :ad, "")
    transcript = Keyword.get(opts, :transcript, :ir)
    scalar = Keyword.get_lazy(opts, :scalar, &sample_scalar/0)

    generator = calculate_generator(prs, ci, sid)

    with {:ok, share} <- scalar_mult_vfy(scalar, generator) do
      {:ok,
       %__MODULE__{
         role: role,
         sid: sid,
         ad: ad,
         scalar: scalar,
         share: share,
         transcript: transcript
       }}
    end
  end

  @doc "This party's public share — `Ya` for role `:a`, `Yb` for role `:b`."
  @spec public_share(t()) :: binary()
  def public_share(%__MODULE__{share: share}), do: share

  @doc "This party's associated data, as sent alongside the public share."
  @spec associated_data(t()) :: binary()
  def associated_data(%__MODULE__{ad: ad}), do: ad

  @doc """
  Complete the run against the peer's public share and associated data,
  returning the 64-byte ISK (draft Section 7.2).

  Returns `:error` when the peer share is malformed or encodes a low-order
  point, which is the mandatory abort condition.
  """
  @spec finish(t(), binary(), binary()) :: {:ok, binary()} | :error
  def finish(%__MODULE__{} = state, peer_share, peer_ad \\ "") do
    with {:ok, k} <- scalar_mult_vfy(state.scalar, peer_share) do
      {ya, ada, yb, adb} = order_shares(state, peer_share, peer_ad)

      transcript =
        case state.transcript do
          :ir -> transcript_ir(ya, ada, yb, adb)
          :oc -> transcript_oc(ya, ada, yb, adb)
        end

      {:ok, :crypto.hash(@hash, lv_cat([@isk_dsi, state.sid, k]) <> transcript)}
    end
  end

  # -- Group environment G_X25519 (draft Section 8.2) --

  @doc "`G.sample_scalar()` — 32 uniformly random bytes; X25519 clamps internally."
  @spec sample_scalar() :: binary()
  def sample_scalar, do: :crypto.strong_rand_bytes(@field_size_bytes)

  @doc """
  `G.calculate_generator(H, PRS, CI, sid)`: hash the generator string to a
  field element and map it onto the curve with Elligator 2.
  """
  @spec calculate_generator(binary(), binary(), binary()) :: binary()
  def calculate_generator(prs, ci, sid) do
    gen_str = generator_string(prs, ci, sid)
    gen_str_hash = binary_part(:crypto.hash(@hash, gen_str), 0, @field_size_bytes)

    gen_str_hash
    |> Field.decode_u_coordinate()
    |> Field.map_to_curve_elligator2()
    |> Field.encode_u_coordinate()
  end

  @doc """
  `generator_string(DSI, PRS, CI, sid, H.s_in_bytes)` (draft Appendix A.2).

  The zero padding makes the first hash block depend only on the domain
  separator and PRS, so short-password runs hash a constant number of bytes.
  """
  @spec generator_string(binary(), binary(), binary()) :: binary()
  def generator_string(prs, ci, sid) do
    len_zpad =
      max(
        0,
        @hash_block_bytes - 1 - byte_size(prepend_len(prs)) - byte_size(prepend_len(@dsi))
      )

    lv_cat([@dsi, prs, :binary.copy(<<0>>, len_zpad), ci, sid])
  end

  @doc """
  `G.scalar_mult_vfy(y, g)` — `X25519(y, g)`, aborting when the result is
  the neutral element.

  OpenSSL signals the all-zero X25519 output by failing the derive, which
  surfaces as an `ErlangError`; that failure *is* the draft's validity
  check, so it maps to `:error` rather than propagating. The explicit
  comparison against `G.I` is the backstop for a libcrypto build that
  returns the zero string instead of erroring — Nerves targets link their
  own OpenSSL.
  """
  @spec scalar_mult_vfy(binary(), binary()) :: {:ok, binary()} | :error
  def scalar_mult_vfy(scalar, u)
      when byte_size(scalar) == @field_size_bytes and byte_size(u) == @field_size_bytes do
    case :crypto.compute_key(:ecdh, u, scalar, :x25519) do
      @neutral_element -> :error
      k -> {:ok, k}
    end
  rescue
    ErlangError -> :error
  end

  def scalar_mult_vfy(_scalar, _u), do: :error

  # -- String utilities (draft Section 6.3, Appendix A.1/A.3) --

  @doc "Prepend the LEB128-encoded length of `data` to `data`."
  @spec prepend_len(binary()) :: binary()
  def prepend_len(data), do: leb128(byte_size(data)) <> data

  @doc "Concatenate each input with its length prepended."
  @spec lv_cat([binary()]) :: binary()
  def lv_cat(items), do: Enum.map_join(items, &prepend_len/1)

  @doc """
  Ordered concatenation: the lexicographically larger string first, behind
  the two-byte tag `"oc"`.
  """
  @spec o_cat(binary(), binary()) :: binary()
  def o_cat(a, b) do
    if lexicographically_larger?(a, b), do: "oc" <> a <> b, else: "oc" <> b <> a
  end

  @doc "Transcript for the initiator/responder setting."
  @spec transcript_ir(binary(), binary(), binary(), binary()) :: binary()
  def transcript_ir(ya, ada, yb, adb), do: lv_cat([ya, ada]) <> lv_cat([yb, adb])

  @doc "Transcript for the symmetric setting, where message order is not enforced."
  @spec transcript_oc(binary(), binary(), binary(), binary()) :: binary()
  def transcript_oc(ya, ada, yb, adb), do: o_cat(lv_cat([ya, ada]), lv_cat([yb, adb]))

  # -- Internals --

  defp order_shares(%__MODULE__{role: :a} = state, peer_share, peer_ad),
    do: {state.share, state.ad, peer_share, peer_ad}

  defp order_shares(%__MODULE__{role: :b} = state, peer_share, peer_ad),
    do: {peer_share, peer_ad, state.share, state.ad}

  defp leb128(len) when len < 128, do: <<len>>

  defp leb128(len), do: <<(len &&& 0x7F) + 0x80>> <> leb128(len >>> 7)

  # Byte-wise comparison, falling back to length when one string is a prefix
  # of the other. Erlang's own binary ordering already does exactly this, but
  # spelling it out keeps the tie-break auditable against Appendix A.3.1.
  defp lexicographically_larger?(<<x, rest_a::binary>>, <<x, rest_b::binary>>),
    do: lexicographically_larger?(rest_a, rest_b)

  defp lexicographically_larger?(<<a, _::binary>>, <<b, _::binary>>), do: a > b
  defp lexicographically_larger?(a, b), do: byte_size(a) > byte_size(b)
end
