defmodule UniversalProxy.FirmwareUpdate.FwupTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.FirmwareUpdate.Fwup

  describe "pre-flight error handling (host-safe)" do
    test "returns :missing_devpath when devpath is nil" do
      tmp_fw = write_tmp("dummy")
      assert {:error, :missing_devpath} = Fwup.apply(tmp_fw, fwup_path: "/usr/bin/fwup")
    end

    test "returns {:firmware_not_found, _} when the .fw file does not exist" do
      assert {:error, {:firmware_not_found, "/no/such/file.fw"}} =
               Fwup.apply("/no/such/file.fw", fwup_path: "/usr/bin/fwup", devpath: "/tmp/x")
    end
  end

  describe "fwup integration (requires fwup on PATH)" do
    @describetag :hardware

    test "applies a tiny .fw against a loopback file" do
      # Skipped by default. Run with: mise run test -- --include hardware
      fwup = System.find_executable("fwup")
      assert fwup, "fwup not installed; run with --include hardware only on a host with fwup"

      tmp_dir = Path.join(System.tmp_dir!(), "fwup_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf(tmp_dir) end)

      conf_path = Path.join(tmp_dir, "fwup.conf")
      fw_path = Path.join(tmp_dir, "test.fw")
      dest_path = Path.join(tmp_dir, "dest.img")

      File.write!(conf_path, """
      meta-product = "fwup test"
      meta-version = "1.0.0"
      meta-platform = "test"
      meta-architecture = "test"
      meta-author = "test"

      file-resource rootfs.img {
        host-path = "rootfs.img"
      }

      task upgrade {
        on-resource rootfs.img {
          raw_write(0)
        }
      }
      """)

      File.write!(Path.join(tmp_dir, "rootfs.img"), :crypto.strong_rand_bytes(8 * 1024))
      File.touch!(dest_path)

      {_, 0} =
        System.cmd("fwup", ["-c", "-f", conf_path, "-o", fw_path],
          cd: tmp_dir,
          stderr_to_stdout: true
        )

      test_pid = self()
      progress = fn event -> send(test_pid, {:progress, event}) end

      assert :ok = Fwup.apply(fw_path, devpath: dest_path, progress: progress)
      assert_received {:progress, {:flashing, _}}, "expected at least one progress event"
    end
  end

  defp write_tmp(content) do
    path = Path.join(System.tmp_dir!(), "fwup_test_#{System.unique_integer([:positive])}.fw")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
