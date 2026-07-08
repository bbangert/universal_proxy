defmodule UniversalProxy.IdentifyTest do
  # Exercises the whole park/blink/restore cycle against a tmp-dir fake
  # /sys/class/leds tree; ms-scale timing via the half_period_ms:/toggles: opts.
  #
  # async: false — Identify's "which LED / none found" messages are info-level,
  # below the test env's :warning primary level, so the setup temporarily
  # lowers the GLOBAL Logger level to let capture_log see them.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias UniversalProxy.Identify

  @moduletag :tmp_dir

  setup do
    prev = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: prev) end)
  end

  # 2 toggles at 1 ms — the full cycle in ~2 ms.
  @fast [half_period_ms: 1, toggles: 2]

  defp make_led(root, name, opts \\ []) do
    led = Path.join(root, name)
    File.mkdir_p!(led)
    File.write!(Path.join(led, "brightness"), "0")
    File.write!(Path.join(led, "max_brightness"), "255\n")
    File.write!(Path.join(led, "trigger"), Keyword.get(opts, :trigger, "none timer [mmc0]"))
    led
  end

  test "prefers ACT and leaves led0 untouched", %{tmp_dir: root} do
    act = make_led(root, "ACT")
    led0 = make_led(root, "led0")

    log = capture_log([level: :info], fn -> assert :ok = Identify.blink_act_led(root, @fast) end)

    assert log =~ "blinking #{act}"
    # ACT's trigger was parked + restored (the fake file now holds the bare
    # restored value); led0 was never written.
    assert File.read!(Path.join(act, "trigger")) == "mmc0"
    assert File.read!(Path.join(led0, "trigger")) == "none timer [mmc0]"
  end

  test "falls back to led0 when ACT is absent", %{tmp_dir: root} do
    led0 = make_led(root, "led0")

    log = capture_log([level: :info], fn -> assert :ok = Identify.blink_act_led(root, @fast) end)

    assert log =~ "blinking #{led0}"
    assert File.read!(Path.join(led0, "trigger")) == "mmc0"
  end

  test "no activity LED: returns :ok and only logs", %{tmp_dir: root} do
    log = capture_log([level: :info], fn -> assert :ok = Identify.blink_act_led(root, @fast) end)
    assert log =~ "no activity LED"
  end

  test "restores the [bracketed] trigger and turns the LED off", %{tmp_dir: root} do
    led = make_led(root, "ACT", trigger: "none heartbeat [heartbeat] timer")

    capture_log(fn -> Identify.blink_act_led(root, @fast) end)

    assert File.read!(Path.join(led, "trigger")) == "heartbeat"
    assert File.read!(Path.join(led, "brightness")) == "0"
  end

  test "an unparseable trigger file skips the restore without crashing", %{tmp_dir: root} do
    led = make_led(root, "ACT", trigger: "garbage with no brackets")

    capture_log(fn -> assert :ok = Identify.blink_act_led(root, @fast) end)

    # Parked to "none" and left there — no bracketed original to restore.
    assert File.read!(Path.join(led, "trigger")) == "none"
    assert File.read!(Path.join(led, "brightness")) == "0"
  end

  test "a failed trigger restore is logged", %{tmp_dir: root} do
    led = make_led(root, "ACT")
    trigger_file = Path.join(led, "trigger")
    File.chmod!(trigger_file, 0o444)
    on_exit(fn -> File.chmod!(trigger_file, 0o644) end)

    log = capture_log([level: :info], fn -> assert :ok = Identify.blink_act_led(root, @fast) end)

    assert log =~ "failed to restore #{led} trigger mmc0"
  end
end
