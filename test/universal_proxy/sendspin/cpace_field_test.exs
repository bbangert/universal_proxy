defmodule UniversalProxy.Sendspin.CPace.FieldTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Sendspin.CPace.Field

  # Vectors: draft-irtf-cfrg-cpace-21 Appendix B.1.1 (group X25519).
  @gen_str_hash "03998087bdb1a2617bbe25ef5a7c18cd4f84f902328701790958755ee4aed1d3"
  @decoded_field_element "03998087bdb1a2617bbe25ef5a7c18cd4f84f902328701790958755ee4aed153"
  @generator "d04bf6d41f6a289632a2e929fa29bebd51092512a7829fdde7d314b62f05a73f"

  defp hex(s), do: Base.decode16!(s, case: :mixed)

  describe "u-coordinate codec (RFC 7748 via draft Appendix A.4)" do
    test "decode masks bit #255 (draft B.1.1 intermediate)" do
      u = Field.decode_u_coordinate(hex(@gen_str_hash))
      assert Field.encode_u_coordinate(u) == hex(@decoded_field_element)
    end

    test "encode is little-endian and 32 bytes wide" do
      assert Field.encode_u_coordinate(1) == <<1>> <> :binary.copy(<<0>>, 31)
      assert byte_size(Field.encode_u_coordinate(Field.p() - 1)) == 32
    end

    test "decode/encode round-trip for already-masked values" do
      for _ <- 1..50 do
        bytes = :crypto.strong_rand_bytes(32)
        u = Field.decode_u_coordinate(bytes)
        assert Field.decode_u_coordinate(Field.encode_u_coordinate(u)) == u
      end
    end
  end

  describe "field arithmetic" do
    test "inv/1 is a multiplicative inverse" do
      for _ <- 1..25 do
        a = Field.decode_u_coordinate(:crypto.strong_rand_bytes(32))
        if a > 0, do: assert(Integer.mod(a * Field.inv(a), Field.p()) == 1)
      end
    end

    test "legendre/1 distinguishes squares, non-squares and zero" do
      p = Field.p()
      assert Field.legendre(0) == 0
      # 4 = 2^2 is a square; 2 is the Elligator 2 non-square Z for Curve25519.
      assert Field.legendre(4) == 1
      assert Field.legendre(2) == p - 1

      for _ <- 1..25 do
        a = Integer.mod(:binary.decode_unsigned(:crypto.strong_rand_bytes(32)), p)

        if a > 0 do
          assert Field.legendre(Integer.mod(a * a, p)) == 1
          assert Field.legendre(Integer.mod(2 * a * a, p)) == p - 1
        end
      end
    end
  end

  describe "map_to_curve_elligator2/1" do
    test "matches the draft B.1.1 generator" do
      u = Field.decode_u_coordinate(hex(@gen_str_hash))

      assert u
             |> Field.map_to_curve_elligator2()
             |> Field.encode_u_coordinate() == hex(@generator)
    end

    test "output is always a valid Curve25519 u-coordinate (curve or twist)" do
      # Elligator 2 is a bijection onto curve-or-twist u-coordinates, so
      # X25519 must accept every output. A rejected output means we produced
      # a low-order point, which would break generator derivation.
      scalar = :crypto.strong_rand_bytes(32)

      for _ <- 1..50 do
        g =
          :crypto.strong_rand_bytes(32)
          |> Field.decode_u_coordinate()
          |> Field.map_to_curve_elligator2()
          |> Field.encode_u_coordinate()

        assert byte_size(g) == 32
        assert is_binary(:crypto.compute_key(:ecdh, g, scalar, :x25519))
      end
    end

    test "is deterministic" do
      u = Field.decode_u_coordinate(:crypto.strong_rand_bytes(32))
      assert Field.map_to_curve_elligator2(u) == Field.map_to_curve_elligator2(u)
    end
  end
end
