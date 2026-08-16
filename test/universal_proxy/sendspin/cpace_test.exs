defmodule UniversalProxy.Sendspin.CPaceTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Sendspin.CPace

  # All vectors below are draft-irtf-cfrg-cpace-21 Appendix A (string
  # utilities) and Appendix B.1 (CPACE-X25519-SHA512).

  @prs "Password"
  @ci "0B415F696E69746961746F720B425F726573706F6E646572"
  @sid "7E4B4791D6A8EF019B936C79FB7F2C57"

  @generator_string "0843506163653235350850617373776f72646d" <>
                      String.duplicate("00", 109) <>
                      "180b415f696e69746961746f720b425f726573706f6e646572" <>
                      "107e4b4791d6a8ef019b936c79fb7f2c57"

  @generator "D04BF6D41F6A289632A2E929FA29BEBD51092512A7829FDDE7D314B62F05A73F"

  @ya "21B4F4BD9E64ED355C3EB676A28EBEDAF6D8F17BDC365995B319097153044080"
  @ada "414461"
  @ya_pub "1D13C89278CDADD826F6D8D7F887701430F8380DDC17611CDD6DC989CE0C9F32"

  @yb "848B0779FF415F0AF4EA14DF9DD1D3C29AC41D836C7808896C4EBA19C51AC40A"
  @adb "414462"
  @yb_pub "248CCCF6D5CDC3646F0AD593F9E6CEF4E69D4945F8372E623512ECEA32185623"

  @k "5B067EFFBDC0B2A0E1D907B21EBB25CFEDB96A852179A847C37E43EE71322C6B"

  @transcript_ir "201d13c89278cdadd826f6d8d7f887701430f8380ddc17611cdd6dc989ce0c9f32" <>
                   "0341446120248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e6235" <>
                   "12ecea3218562303414462"

  @transcript_oc "6f6320248cccf6d5cdc3646f0ad593f9e6cef4e69d4945f8372e623512ecea32" <>
                   "18562303414462201d13c89278cdadd826f6d8d7f887701430f8380ddc176" <>
                   "11cdd6dc989ce0c9f3203414461"

  @isk_ir "6E19B875F7A561D6B3CA3DBB9EF42AC55DE3E717881018204B8922B4D5E53BB2" <>
            "AA82C300BEA7B65D2B671DA71922DDF6472301B79BC270ADFA8BF413285F2263"

  @isk_oc "EEF745E2F6E7AE2B1A1E53DA340E777167A07FE150436648C51FB199C11F3CBA" <>
            "BFC683A2B48E1AF5881940DC398D375C95E6B4AE9948A45B8770DE0656382BE4"

  # Appendix B.1.10: u-coordinates that scalar_mult_vfy must reject (they
  # encode low-order points on the curve or its twist), and ones it must
  # accept, all under the same scalar.
  @vfy_scalar "af46e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449aff"

  @invalid_u ~w(
    0000000000000000000000000000000000000000000000000000000000000000
    0100000000000000000000000000000000000000000000000000000000000000
    ECFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F
    E0EB7A7C3B41B8AE1656E3FAF19FC46ADA098DEB9C32B1FD866205165F49B800
    5F9C95BCA3508C24B1D0B1559C83EF5B04445CC4581C8E86D8224EDDD09F1157
    EDFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F
    EEFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF7F
  )

  # Non-canonical representations with bit #255 set; decodeUCoordinate must
  # clear that bit, after which these are ordinary points with non-zero
  # results (draft Section 8.2.1).
  @valid_u [
    {"DAFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
     "d8e2c776bbacd510d09fd9278b7edcd25fc5ae9adfba3b6e040e8d3b71b21806"},
    {"DBFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
     "c85c655ebe8be44ba9c0ffde69f2fe10194458d137f09bbff725ce58803cdb38"},
    {"D9FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
     "db64dafa9b8fdd136914e61461935fe92aa372cb056314e1231bc4ec12417456"},
    {"CDEB7A7C3B41B8AE1656E3FAF19FC46ADA098DEB9C32B1FD866205165F49B880",
     "e062dcd5376d58297be2618c7498f55baa07d7e03184e8aada20bca28888bf7a"},
    {"4C9C95BCA3508C24B1D0B1559C83EF5B04445CC4581C8E86D8224EDDD09F11D7",
     "993c6ad11c4c29da9a56f7691fd0ff8d732e49de6250b6c2e80003ff4629a175"}
  ]

  defp hex(s), do: Base.decode16!(s, case: :mixed)

  defp run(a_opts, b_opts) do
    {:ok, a} = CPace.start(:a, a_opts)
    {:ok, b} = CPace.start(:b, b_opts)

    {CPace.finish(a, CPace.public_share(b), CPace.associated_data(b)),
     CPace.finish(b, CPace.public_share(a), CPace.associated_data(a))}
  end

  describe "string utilities (Appendix A.1, A.3)" do
    test "prepend_len/1 LEB128 vectors" do
      assert CPace.prepend_len("") == hex("00")
      assert CPace.prepend_len("1234") == hex("0431323334")

      short = :binary.list_to_bin(Enum.to_list(0..126))
      assert CPace.prepend_len(short) == <<0x7F>> <> short

      long = :binary.list_to_bin(Enum.to_list(0..127))
      assert CPace.prepend_len(long) == <<0x80, 0x01>> <> long
    end

    test "lv_cat/1 vector" do
      assert CPace.lv_cat(["1234", "5", "", "678"]) == hex("043132333401350003363738")
    end

    test "o_cat/2 vectors" do
      assert CPace.o_cat("ABCD", "BCD") == hex("6f6342434441424344")
      assert CPace.o_cat("BCD", "ABCDE") == hex("6f634243444142434445")
    end

    test "transcript_ir/4 vectors" do
      assert CPace.transcript_ir("123", "PartyA", "234", "PartyB") ==
               hex("03313233065061727479410332333406506172747942")

      assert CPace.transcript_ir("3456", "PartyA", "2345", "PartyB") ==
               hex("043334353606506172747941043233343506506172747942")
    end

    test "transcript_oc/4 vectors" do
      assert CPace.transcript_oc("123", "PartyA", "234", "PartyB") ==
               hex("6f6303323334065061727479420331323306506172747941")

      assert CPace.transcript_oc("3456", "PartyA", "2345", "PartyB") ==
               hex("6f63043334353606506172747941043233343506506172747942")
    end
  end

  describe "calculate_generator (Appendix B.1.1)" do
    test "generator_string/3 matches the vector, including the 109-byte zero pad" do
      gen_str = CPace.generator_string(@prs, hex(@ci), hex(@sid))
      assert byte_size(gen_str) == 170
      assert gen_str == hex(@generator_string)
    end

    test "calculate_generator/3 matches the vector" do
      assert CPace.calculate_generator(@prs, hex(@ci), hex(@sid)) == hex(@generator)
    end

    test "a different PRS yields a different generator" do
      refute CPace.calculate_generator("Passwore", hex(@ci), hex(@sid)) == hex(@generator)
    end
  end

  describe "scalar_mult_vfy (Appendix B.1.10)" do
    test "rejects low-order points" do
      for u <- @invalid_u do
        assert CPace.scalar_mult_vfy(hex(@vfy_scalar), hex(u)) == :error,
               "expected abort for u = #{u}"
      end
    end

    test "accepts non-canonical encodings with bit #255 set" do
      for {u, q} <- @valid_u do
        assert CPace.scalar_mult_vfy(hex(@vfy_scalar), hex(u)) == {:ok, hex(q)}
      end
    end

    test "rejects wrongly sized inputs" do
      assert CPace.scalar_mult_vfy(<<0>>, hex(@generator)) == :error
      assert CPace.scalar_mult_vfy(hex(@vfy_scalar), <<0>>) == :error
    end
  end

  describe "protocol run against the Appendix B.1 vectors" do
    setup do
      {:ok, a} =
        CPace.start(:a, prs: @prs, ci: hex(@ci), sid: hex(@sid), ad: hex(@ada), scalar: hex(@ya))

      {:ok, b} =
        CPace.start(:b, prs: @prs, ci: hex(@ci), sid: hex(@sid), ad: hex(@adb), scalar: hex(@yb))

      %{a: a, b: b}
    end

    test "public shares match B.1.2 / B.1.3", %{a: a, b: b} do
      assert CPace.public_share(a) == hex(@ya_pub)
      assert CPace.public_share(b) == hex(@yb_pub)
      assert CPace.associated_data(a) == hex(@ada)
      assert CPace.associated_data(b) == hex(@adb)
    end

    test "both sides derive the secret point K from B.1.4" do
      assert CPace.scalar_mult_vfy(hex(@ya), hex(@yb_pub)) == {:ok, hex(@k)}
      assert CPace.scalar_mult_vfy(hex(@yb), hex(@ya_pub)) == {:ok, hex(@k)}
    end

    test "transcripts match B.1.5 / B.1.6" do
      assert CPace.transcript_ir(hex(@ya_pub), hex(@ada), hex(@yb_pub), hex(@adb)) ==
               hex(@transcript_ir)

      assert CPace.transcript_oc(hex(@ya_pub), hex(@ada), hex(@yb_pub), hex(@adb)) ==
               hex(@transcript_oc)
    end

    test "initiator/responder ISK matches B.1.5 on both sides", %{a: a, b: b} do
      assert CPace.finish(a, hex(@yb_pub), hex(@adb)) == {:ok, hex(@isk_ir)}
      assert CPace.finish(b, hex(@ya_pub), hex(@ada)) == {:ok, hex(@isk_ir)}
    end

    test "symmetric-transcript ISK matches B.1.6 on both sides" do
      opts = [prs: @prs, ci: hex(@ci), sid: hex(@sid), transcript: :oc]
      {:ok, a} = CPace.start(:a, opts ++ [ad: hex(@ada), scalar: hex(@ya)])
      {:ok, b} = CPace.start(:b, opts ++ [ad: hex(@adb), scalar: hex(@yb)])

      assert CPace.finish(a, hex(@yb_pub), hex(@adb)) == {:ok, hex(@isk_oc)}
      assert CPace.finish(b, hex(@ya_pub), hex(@ada)) == {:ok, hex(@isk_oc)}
    end

    test "finish/3 aborts on a low-order peer share", %{b: b} do
      for u <- @invalid_u do
        assert CPace.finish(b, hex(u), hex(@ada)) == :error
      end
    end
  end

  describe "randomized round-trip" do
    test "matching inputs converge on one ISK" do
      for _ <- 1..25 do
        prs = :crypto.strong_rand_bytes(6)
        sid = :crypto.strong_rand_bytes(16)
        ci = :crypto.strong_rand_bytes(8)
        common = [prs: prs, ci: ci, sid: sid]

        {{:ok, isk_a}, {:ok, isk_b}} =
          run(common ++ [ad: "server"], common ++ [ad: "client"])

        assert isk_a == isk_b
        assert byte_size(isk_a) == 64
      end
    end

    test "fresh scalars make every run produce a different ISK" do
      common = [prs: "483106", sid: :crypto.strong_rand_bytes(16)]

      isks =
        for _ <- 1..10 do
          {{:ok, isk}, {:ok, same}} = run(common, common)
          assert isk == same
          isk
        end

      assert length(Enum.uniq(isks)) == 10
    end

    test "a mismatched PRS yields different ISKs" do
      sid = :crypto.strong_rand_bytes(16)

      {{:ok, isk_a}, {:ok, isk_b}} =
        run([prs: "483106", sid: sid], prs: "483107", sid: sid)

      refute isk_a == isk_b
    end

    test "mismatched sid or CI yields different ISKs" do
      base = [prs: "483106", ci: "chan", sid: "sid-1"]

      for {a_opts, b_opts} <- [
            {base, Keyword.put(base, :sid, "sid-2")},
            {base, Keyword.put(base, :ci, "chad")}
          ] do
        {{:ok, isk_a}, {:ok, isk_b}} = run(a_opts, b_opts)
        refute isk_a == isk_b
      end
    end

    test "a tampered peer AD yields different ISKs" do
      # AD travels in the clear, so it is authenticated only by ending up in
      # both transcripts: if A's AD is altered in flight, B's ISK diverges.
      common = [prs: "483106", sid: "sid-1"]
      {:ok, a} = CPace.start(:a, common ++ [ad: "server"])
      {:ok, b} = CPace.start(:b, common ++ [ad: "client"])

      {:ok, isk_a} = CPace.finish(a, CPace.public_share(b), "client")
      {:ok, isk_b} = CPace.finish(b, CPace.public_share(a), "attacker")

      refute isk_a == isk_b
    end

    test "role assignment orders the transcript, so two same-role parties disagree" do
      common = [prs: "483106", sid: "sid-1", ad: "x"]
      {:ok, a1} = CPace.start(:a, common)
      {:ok, a2} = CPace.start(:a, common)

      {:ok, isk_1} = CPace.finish(a1, CPace.public_share(a2), "x")
      {:ok, isk_2} = CPace.finish(a2, CPace.public_share(a1), "x")

      refute isk_1 == isk_2
    end
  end
end
