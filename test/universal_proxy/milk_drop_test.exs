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

  test "a Pack crash stops its running installer before Pack restarts", %{tmp_dir: tmp_dir} do
    test_pid = self()

    # Runs inside the installer task: Req calls a function plug in-process.
    plug = fn conn ->
      send(test_pid, {:installing, self()})

      receive do
        :never -> conn
      after
        10_000 -> conn
      end
    end

    pin = %{
      version: "2026.11.1",
      url: "https://example.test/pack.tar.gz",
      sha256: String.duplicate("0", 64)
    }

    start_supervised!(
      {MilkDrop.Supervisor,
       enabled: true,
       name: :milkdrop_supervisor_test,
       store: [table: :milkdrop_supervisor_test, dets_path: Path.join(tmp_dir, "settings.dets")],
       pack: [root: tmp_dir, pin: pin, req_options: [plug: plug]]}
    )

    assert {:downloading, 0} = MilkDrop.Pack.ensure()
    assert_receive {:installing, installer}, 5_000
    ref = Process.monitor(installer)
    old_pack = Process.whereis(MilkDrop.Pack)

    Process.exit(old_pack, :kill)
    assert_receive {:DOWN, ^ref, :process, ^installer, _}, 5_000
    wait_until(fn -> Process.whereis(MilkDrop.Pack) not in [nil, old_pack] end)
    assert MilkDrop.Pack.status() == :absent
  end

  defp wait_until(fun, timeout \\ 5_000) do
    cond do
      fun.() ->
        :ok

      timeout <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(20)
        wait_until(fun, timeout - 20)
    end
  end

  test "the public APIs degrade while the subtree is off" do
    assert MilkDrop.Store.settings() == MilkDrop.Store.defaults()
    assert MilkDrop.Store.skipped("v1") == %{}
    assert MilkDrop.Pack.status() == {:error, :not_running}
    assert MilkDrop.Pack.ensure() == {:error, :not_running}
  end
end
