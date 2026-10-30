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
end
