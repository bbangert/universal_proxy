defmodule UniversalProxy.Cec.MonitorTest do
  # async: false — broadcasts on the shared "cec:events" topic.
  use ExUnit.Case, async: false

  alias UniversalProxy.Cec.Monitor

  @dev "/dev/cec0"

  setup do
    dir = Path.join(System.tmp_dir!(), "cec_monitor_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    Phoenix.PubSub.subscribe(UniversalProxy.PubSub, Monitor.topic())
    {:ok, dir: dir}
  end

  # A cec-ctl stand-in that prints `output`, records its pid, then idles with
  # stdin and SIGHUP ignored, as `cec-ctl -m` does on a quiet bus.
  defp fake_ctl(dir, output) do
    path = Path.join(dir, "cec-ctl")
    pidfile = Path.join(dir, "pid")

    File.write!(path, """
    #!/bin/sh
    trap "" HUP
    echo $$ > #{pidfile}
    printf '%b' '#{output}'
    while :; do sleep 1; done
    """)

    File.chmod!(path, 0o755)
    {path, pidfile}
  end

  test "a message followed by silence is broadcast", %{dir: dir} do
    {binary, _pidfile} =
      fake_ctl(
        dir,
        "Received from TV to all (0 to 15): STANDBY (0x36)\\n" <>
          "\\tSequence: 4 Rx Timestamp: 1234.560000s\\n"
      )

    start_supervised!({Monitor, dev: @dev, binary: binary})

    assert_receive {:cec_event, @dev, %{type: :message, opcode: "STANDBY", from: 0, to: :all}},
                   2_000
  end

  @tag :capture_log
  test "killing the monitor also kills its cec-ctl process", %{dir: dir} do
    {binary, pidfile} = fake_ctl(dir, "")
    monitor = start_supervised!({Monitor, dev: @dev, binary: binary}, restart: :temporary)

    os_pid = wait_for_pid(pidfile)
    assert alive?(os_pid)

    ref = Process.monitor(monitor)
    Process.exit(monitor, :kill)
    assert_receive {:DOWN, ^ref, :process, ^monitor, :killed}

    assert wait_until(fn -> not alive?(os_pid) end),
           "cec-ctl stand-in #{os_pid} outlived its monitor"
  end

  defp wait_for_pid(pidfile) do
    assert wait_until(fn -> match?({:ok, <<_, _::binary>>}, File.read(pidfile)) end)
    pidfile |> File.read!() |> String.trim()
  end

  defp alive?(os_pid) do
    match?({_, 0}, System.cmd("kill", ["-0", os_pid], stderr_to_stdout: true))
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        true

      attempts > 0 ->
        Process.sleep(20)
        wait_until(fun, attempts - 1)

      true ->
        false
    end
  end
end
