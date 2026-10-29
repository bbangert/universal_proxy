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
  end
end
