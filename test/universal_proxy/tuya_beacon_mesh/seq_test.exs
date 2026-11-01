defmodule UniversalProxy.TuyaBeaconMesh.SeqTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.TuyaBeaconMesh.Seq

  test "reserves a block and advances the persisted cursor" do
    seq = Seq.new(100)
    assert {:ok, sns, seq2} = Seq.reserve(seq, 4)
    assert sns == [100, 101, 102, 103]
    assert Seq.value(seq2) == 104
  end

  test "wraps at 65536 and rejects oversized blocks" do
    assert {:ok, [65_534, 65_535, 0], seq} = Seq.reserve(Seq.new(65_534), 3)
    assert Seq.value(seq) == 1
    assert {:error, :block_too_large} = Seq.reserve(Seq.new(0), 100)
    assert {:error, :bad_block_size} = Seq.reserve(Seq.new(0), 0)
    assert {:error, :bad_block_size} = Seq.reserve(Seq.new(0), -1)
    assert {:ok, sns, _} = Seq.reserve(Seq.new(0), 99)
    assert length(sns) == 99
    assert Seq.value(Seq.new(70_000)) == 70_000 - 65_536
  end

  describe "ahead?/2" do
    test "plain forward / backward / equal" do
      assert Seq.ahead?(100, 101)
      refute Seq.ahead?(101, 100)
      refute Seq.ahead?(100, 100)
    end

    test "across the wrap" do
      assert Seq.ahead?(65_530, 5)
      refute Seq.ahead?(5, 65_530)
      assert Seq.ahead?(65_535, 0)
    end

    test "half-range boundary" do
      assert Seq.ahead?(0, 32_767)
      refute Seq.ahead?(0, 32_768)
      refute Seq.ahead?(32_768, 0)
    end
  end

  describe "advance_to/2" do
    test "moves forward, never backward" do
      assert Seq.value(Seq.advance_to(Seq.new(100), 150)) == 150
      assert Seq.value(Seq.advance_to(Seq.new(150), 100)) == 150
      assert Seq.value(Seq.advance_to(Seq.new(150), 150)) == 150
    end

    test "is a serial-number max across the wrap" do
      assert Seq.value(Seq.advance_to(Seq.new(65_530), 5)) == 5
      assert Seq.value(Seq.advance_to(Seq.new(5), 65_530)) == 5
      assert Seq.value(Seq.advance_to(Seq.new(0), 32_768)) == 0
    end

    test "a cursor past a wrapped reserved block keeps it" do
      {:ok, _sns, seq} = Seq.reserve(Seq.new(65_534), 3)
      assert Seq.value(Seq.advance_to(seq, 65_535)) == 1
      assert Seq.value(Seq.advance_to(seq, 2)) == 2
    end
  end

  describe "leases" do
    test "lease/2 moves only the persisted cursor; take/1 hands numbers out" do
      assert {:ok, seq} = Seq.lease(Seq.new(100), 3)
      assert {Seq.next(seq), Seq.value(seq), Seq.remaining(seq)} == {100, 103, 3}

      assert {:ok, 100, seq} = Seq.take(seq)
      assert {:ok, 101, seq} = Seq.take(seq)
      assert {:ok, 102, seq} = Seq.take(seq)
      assert {:error, :lease_exhausted} = Seq.take(seq)
      assert Seq.value(seq) == 103
      assert {:error, :lease_exhausted} = Seq.take(Seq.new(5))
    end

    test "rejects empty and oversized leases" do
      assert Seq.max_lease() == 900
      assert {:ok, seq} = Seq.lease(Seq.new(0), 900)
      assert Seq.value(seq) == 900
      assert {:error, :lease_too_large} = Seq.lease(Seq.new(0), 901)
      assert {:error, :bad_lease_size} = Seq.lease(Seq.new(0), 0)
      assert {:error, :bad_lease_size} = Seq.lease(Seq.new(0), -3)
      assert {:error, :bad_lease_size} = Seq.lease(Seq.new(0), 1.5)
    end

    test "a lease never shortens the one in place" do
      {:ok, seq} = Seq.lease(Seq.new(100), 50)
      {:ok, 100, seq} = Seq.take(seq)
      assert {:ok, same} = Seq.lease(seq, 10)
      assert Seq.value(same) == 150
      assert {:ok, longer} = Seq.lease(seq, 80)
      assert Seq.value(longer) == 181
    end

    test "a large lease wraps past 65535" do
      {:ok, seq} = Seq.lease(Seq.new(65_000), 900)
      assert Seq.value(seq) == 364
      assert Seq.remaining(seq) == 900

      {sns, seq} =
        Enum.map_reduce(1..900, seq, fn _, seq ->
          {:ok, sn, seq} = Seq.take(seq)
          {sn, seq}
        end)

      assert sns == Enum.to_list(65_000..65_535) ++ Enum.to_list(0..363)
      assert {:error, :lease_exhausted} = Seq.take(seq)
      assert Seq.ahead?(List.last(sns), Seq.value(seq))
    end

    test "give_back/2 returns only the number just taken, across the wrap" do
      {:ok, seq} = Seq.lease(Seq.new(65_535), 4)
      {:ok, 65_535, seq} = Seq.take(seq)
      assert Seq.next(Seq.give_back(seq, 65_535)) == 65_535

      {:ok, 0, seq} = Seq.take(seq)
      {:ok, 1, seq} = Seq.take(seq)
      # 0 is not the latest number taken: it stays used.
      assert Seq.give_back(seq, 0) == seq
      assert Seq.give_back(seq, 2) == seq
      back = Seq.give_back(seq, 1)
      assert {:ok, 1, _} = Seq.take(back)
      assert Seq.value(back) == 3
    end

    test "tighten/1 ends the lease at the next number" do
      {:ok, seq} = Seq.lease(Seq.new(65_530), 600)
      {:ok, _, seq} = Seq.take(seq)
      {:ok, _, seq} = Seq.take(seq)

      tight = Seq.tighten(seq)
      assert {Seq.next(tight), Seq.value(tight), Seq.remaining(tight)} == {65_532, 65_532, 0}
      assert {:error, :lease_exhausted} = Seq.take(tight)
      assert Seq.tighten(Seq.new(7)) == Seq.new(7)
    end

    test "reserve/2 and advance_to/2 keep a lease that is still ahead" do
      {:ok, seq} = Seq.lease(Seq.new(100), 50)
      assert {:ok, [100, 101], reserved} = Seq.reserve(seq, 2)
      assert {Seq.next(reserved), Seq.value(reserved)} == {102, 150}

      advanced = Seq.advance_to(seq, 120)
      assert {Seq.next(advanced), Seq.value(advanced)} == {120, 150}

      # Past the lease: it is used up, and the cursors meet.
      past = Seq.advance_to(seq, 200)
      assert {Seq.next(past), Seq.value(past)} == {200, 200}

      # Behind, or ambiguous: nothing changes.
      assert Seq.advance_to(seq, 90) == seq
    end

    test "random lease/take/give_back/tighten keeps the cursor past every number used" do
      for seed <- [1, 2, 3] do
        :rand.seed(:exsss, {seed, seed, seed})
        start = Seq.new(65_000 + :rand.uniform(500))

        Enum.reduce(1..2_000, {start, nil}, fn _, {seq, last} ->
          {seq, last} = random_step(seq, last)

          assert Seq.remaining(seq) <= Seq.max_lease()
          if last, do: assert(Seq.ahead?(last, Seq.next(seq)), "seed #{seed}")
          if last, do: assert(Seq.ahead?(last, Seq.value(seq)), "seed #{seed}")
          {seq, last}
        end)
      end
    end
  end

  # One random operation; `last` is the newest number used (never given
  # back), which every later number and the persisted cursor must pass.
  defp random_step(seq, last) do
    case :rand.uniform(10) do
      n when n <= 6 ->
        case Seq.take(seq) do
          {:ok, sn, seq} ->
            if last, do: assert(Seq.ahead?(last, sn))

            if :rand.uniform(4) == 1,
              do: {Seq.give_back(seq, sn), last},
              else: {seq, sn}

          {:error, :lease_exhausted} ->
            {:ok, seq} = Seq.lease(seq, :rand.uniform(Seq.max_lease()))
            {seq, last}
        end

      n when n <= 8 ->
        {:ok, seq} = Seq.lease(seq, :rand.uniform(Seq.max_lease()))
        {seq, last}

      9 ->
        {Seq.tighten(seq), last}

      10 ->
        {:ok, block, seq} = Seq.reserve(seq, :rand.uniform(99))
        if last, do: assert(Seq.ahead?(last, hd(block)))
        {seq, List.last(block)}
    end
  end
end
