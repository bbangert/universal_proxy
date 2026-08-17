defmodule UniversalProxy.Sendspin.CPace.Field do
  @moduledoc """
  Arithmetic in GF(2^255 - 19) — the Curve25519 base field — plus the
  Elligator 2 map that CPace uses to turn a password hash into a group
  generator.

  Everything here is defined by draft-irtf-cfrg-cpace-21: the u-coordinate
  codecs in Appendix A.4 (lifted from [RFC7748]) and the `elligator2`
  reference implementation in Appendix A.5.

  ## Why there is no square root here

  [RFC9380]'s `map_to_curve_elligator2` produces an affine point `(u, v)`.
  CPace discards `v` (Section 8.2), and the draft's own reference code
  computes only the u-coordinate — which needs the Legendre symbol
  (`t^((p-1)/2)`) but never an actual square root. So `sqrt/1` would be dead
  code and is deliberately absent.

  ## Timing

  The heavy exponentiations run in OpenSSL via `:crypto.mod_pow/3`; the
  surrounding bignum arithmetic is the BEAM's, which is not constant time.
  This is the same posture as every pure-Elixir curve implementation on the
  BEAM. The secret input here is the password-derived field element, and the
  operation sequence does not branch on it: `map_to_curve_elligator2/1` is
  straight-line, with no data-dependent conditionals.
  """

  import Bitwise

  # p = 2^255 - 19
  @p Integer.pow(2, 255) - 19

  # Curve25519 in Montgomery form: B*v^2 = u^3 + A*u^2 + u, with B = 1.
  @curve_a 486_662

  # Elligator 2 needs a non-square Z. draft-21 Appendix A.5's find_z_ell2
  # yields Z = 2 for Curve25519.
  @z 2

  @legendre_exp div(@p - 1, 2)

  # A/2 in the field. A is even, so this is exact integer division.
  @half_curve_a div(@curve_a, 2)

  @field_size_bits 255
  @field_size_bytes 32

  @doc "The field prime, 2^255 - 19."
  @spec p() :: pos_integer()
  def p, do: @p

  @doc "`base^exp mod p`."
  @spec pow(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def pow(base, exp) when base >= 0 and exp >= 0 do
    :crypto.mod_pow(base, exp, @p) |> :binary.decode_unsigned()
  end

  @doc "Multiplicative inverse of `a` via Fermat's little theorem."
  @spec inv(pos_integer()) :: non_neg_integer()
  def inv(a) when a > 0, do: pow(a, @p - 2)

  @doc """
  Legendre symbol of `a`, as a field element: `1` for a non-zero square,
  `p - 1` for a non-square, `0` for zero.
  """
  @spec legendre(non_neg_integer()) :: non_neg_integer()
  def legendre(a), do: pow(a, @legendre_exp)

  @doc """
  `decodeUCoordinate` from [RFC7748] (draft-21 Appendix A.4): little-endian
  32-byte string to field element, with the unused bit #255 masked off.
  """
  @spec decode_u_coordinate(<<_::256>>) :: non_neg_integer()
  def decode_u_coordinate(<<lead::binary-31, msb>>) do
    :binary.decode_unsigned(lead <> <<msb &&& 0x7F>>, :little)
  end

  @doc "`encodeUCoordinate` from [RFC7748]: field element to 32-byte little-endian."
  @spec encode_u_coordinate(non_neg_integer()) :: <<_::256>>
  def encode_u_coordinate(u) when u >= 0 and u < @p do
    <<u::little-unsigned-256>>
  end

  @doc """
  Elligator 2 (draft-21 Appendix A.5): map a field element to a valid
  Curve25519 u-coordinate. Returns the u-coordinate as a field element.
  """
  @spec map_to_curve_elligator2(non_neg_integer()) :: non_neg_integer()
  def map_to_curve_elligator2(r) do
    # v = -A / (1 + Z*r^2). The denominator can never be zero: that would
    # need r^2 = -1/Z, and -1/Z is a non-square (Z is a non-square and -1 is
    # a square for p = 1 mod 4), so it has no square root.
    denom = mod(1 + @z * mod(r * r))
    v = mod(-(@curve_a * inv(denom)))

    # epsilon = legendre(v^3 + A*v^2 + B*v) with B = 1, i.e. 1 when v is a
    # valid u-coordinate on the curve and p-1 when it is on the twist.
    epsilon = legendre(mod(mod(mod(v * v) * v) + mod(@curve_a * mod(v * v)) + v))

    # x = epsilon*v - (1 - epsilon)*A/2: v itself on the curve branch,
    # -v - A on the twist branch.
    mod(epsilon * v - mod(1 - epsilon) * @half_curve_a)
  end

  @doc "Field size in bits (255)."
  @spec field_size_bits() :: pos_integer()
  def field_size_bits, do: @field_size_bits

  @doc "Field size in bytes (32)."
  @spec field_size_bytes() :: pos_integer()
  def field_size_bytes, do: @field_size_bytes

  defp mod(n), do: Integer.mod(n, @p)
end
