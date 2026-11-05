defmodule UniversalProxy.MilkDropTest do
  # async: false — starts the subtree under the Store/Pack module names.
  use ExUnit.Case, async: false

  alias UniversalProxy.MilkDrop

  @moduletag :tmp_dir

  test "disabled on the host build" do
    refute MilkDrop.supported?()
    refute MilkDrop.enabled?()
    assert MilkDrop.Supervisor.start_link() == :ignore
  end

  test "enabled: true starts Store and Pack", %{tmp_dir: tmp_dir} do
    start_supervised!(
      {MilkDrop.Supervisor,
       enabled: true,
       name: :milkdrop_supervisor_test,
       store: [table: :milkdrop_supervisor_test, dets_path: Path.join(tmp_dir, "settings.dets")],
       pack: [root: tmp_dir, pin: nil]}
    )

    assert MilkDrop.Store.settings() == MilkDrop.Store.defaults()
    assert MilkDrop.Pack.status() == :absent
    assert MilkDrop.Pack.ensure() == {:error, :no_pack_pinned}
  end

  test "the public APIs degrade while the subtree is off" do
    assert MilkDrop.Store.settings() == MilkDrop.Store.defaults()
    assert MilkDrop.Store.skipped("v1") == %{}
    assert MilkDrop.Pack.status() == {:error, :not_running}
    assert MilkDrop.Pack.ensure() == {:error, :not_running}
  end
end
