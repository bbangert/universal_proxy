defmodule SendspinPlayerContractTest do
  @moduledoc """
  Locks the BEAM ↔ `sendspin_player` JSON wire contract so a sendspin-cpp
  version bump (or a careless edit to `c_src/sendspin_player/src/main.cpp`)
  can't silently drift before Phase 3's `UniversalProxy.Audio.Player`
  starts parsing these events.

  Spawns the host build of the binary, drives stdin/stdout, and asserts
  the documented event/command shapes. Does not require audio hardware —
  the binary's `start_server()` binds a non-privileged WebSocket port and
  does not touch ALSA until a stream begins.
  """

  use ExUnit.Case, async: false

  @moduletag :contract

  @binary_path :code.priv_dir(:universal_proxy)
               |> to_string()
               |> Path.join(["sendspin_player", "/host/sendspin_player"])

  # Port chosen above the IANA dynamic range floor to avoid collisions with
  # the upstream default (8928).
  @ws_port 18_928

  setup_all do
    unless File.exists?(@binary_path) do
      raise """
      sendspin_player host binary not found at:
        #{@binary_path}

      Run `mix compile` (host target) first. CI builds it automatically
      via the `:sendspin_player` compiler in mix.exs.
      """
    end

    :ok
  end

  setup do
    port = spawn_player()

    # on_exit runs in a separate process, so Port operations from inside it
    # fail with :badarg. Capture the OS PID now and shutdown via signals
    # from the on_exit callback — that survives the test-process lifetime.
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    on_exit(fn -> shutdown_os_process(os_pid) end)

    {:ok,
     port: port, started: assert_started_event(port), volume_event: assert_volume_event(port)}
  end

  test "emits a `started` JSON event with documented fields on launch", %{started: event} do
    assert event["event"] == "started"

    assert is_binary(event["version"]) and event["version"] =~ ~r/^\d+\.\d+\.\d+$/,
           "version should be SemVer, got: #{inspect(event["version"])}"

    assert event["port"] == @ws_port
    assert event["name"] == "contract-test"
    assert event["alsa_device"] == "default"
  end

  test "emits initial `volume` event matching --initial-volume", %{volume_event: event} do
    assert event == %{"event" => "volume", "value" => 42}
  end

  test "set_volume command echoes back as a clamped volume event", %{port: port} do
    send_command(port, ~s({"cmd":"set_volume","value":80}))
    assert next_event(port) == %{"event" => "volume", "value" => 80}

    # Clamping: 999 → 100
    send_command(port, ~s({"cmd":"set_volume","value":999}))
    assert next_event(port) == %{"event" => "volume", "value" => 100}

    # Clamping: -5 → 0
    send_command(port, ~s({"cmd":"set_volume","value":-5}))
    assert next_event(port) == %{"event" => "volume", "value" => 0}
  end

  test "set_muted command echoes back as a mute event", %{port: port} do
    send_command(port, ~s({"cmd":"set_muted","value":true}))
    assert next_event(port) == %{"event" => "mute", "value" => true}

    send_command(port, ~s({"cmd":"set_muted","value":false}))
    assert next_event(port) == %{"event" => "mute", "value" => false}
  end

  test "shutdown command exits cleanly within a few seconds", %{port: port} do
    send_command(port, ~s({"cmd":"shutdown"}))

    assert wait_for_exit(port) == 0,
           "binary should exit 0 on shutdown command"
  end

  test "loose-shape commands are ignored, not parsed", %{port: port} do
    # The OLD substring-matching parser accepted this (`"cmd"` appears
    # inside a nested string value). The strict scanner must reject it
    # — no volume change should happen, and the next legit command must
    # still work.
    send_command(port, ~s({"note":"the \\"cmd\\" trick","cmd":"set_volume","value":99}))

    # Trailing garbage must also be rejected.
    send_command(port, ~s({"cmd":"set_volume","value":50}TRAILING))

    # Sanity: a clean command after the rejections still works.
    send_command(port, ~s({"cmd":"set_volume","value":33}))
    assert next_event(port) == %{"event" => "volume", "value" => 33}
  end

  # ----------------------------------------------------------------------
  # Helpers
  # ----------------------------------------------------------------------

  defp spawn_player do
    Port.open(
      {:spawn_executable, String.to_charlist(@binary_path)},
      [
        :binary,
        :exit_status,
        {:line, 1024},
        args: [
          "--name",
          "contract-test",
          "--client-id",
          "contract-uuid-0001",
          "--mdns-port",
          Integer.to_string(@ws_port),
          "--alsa-device",
          "default",
          "--initial-volume",
          "42",
          "--log-level",
          "error"
        ]
      ]
    )
  end

  defp assert_started_event(port), do: receive_event(port, "started")
  defp assert_volume_event(port), do: receive_event(port, "volume")

  defp receive_event(port, expected_event_kind) do
    event = next_event(port)

    assert event["event"] == expected_event_kind,
           "expected event `#{expected_event_kind}`, got: #{inspect(event)}"

    event
  end

  defp next_event(port) do
    receive do
      {^port, {:data, {:eol, line}}} -> Jason.decode!(line)
    after
      5_000 -> flunk("no JSON event received within 5s")
    end
  end

  defp send_command(port, json) when is_binary(json) do
    Port.command(port, json <> "\n")
  end

  defp wait_for_exit(port) do
    receive do
      {^port, {:exit_status, status}} -> status
      {^port, {:data, _}} -> wait_for_exit(port)
    after
      3_000 -> flunk("binary did not exit within 3s of shutdown command")
    end
  end

  # Sends SIGTERM (graceful), then SIGKILL after a grace period. Run from
  # on_exit which lives in a different process than the test, so we can't
  # talk to the port directly here. `kill -0` checks existence; non-zero
  # means the process is already gone, which is the success path.
  defp shutdown_os_process(nil), do: :ok

  defp shutdown_os_process(os_pid) do
    pid_str = to_string(os_pid)

    case System.cmd("kill", ["-0", pid_str], stderr_to_stdout: true) do
      {_, 0} ->
        System.cmd("kill", ["-TERM", pid_str], stderr_to_stdout: true)
        Process.sleep(200)
        System.cmd("kill", ["-KILL", pid_str], stderr_to_stdout: true)

      _ ->
        :ok
    end
  end
end
