defmodule UniversalProxy.Identify do
  @moduledoc """
  Physically identify this device: blink the board's activity LED for ~10 s.

  Wired as Improv's `identify_fun:` (see `UniversalProxy.Bluetooth.bluez_spec/0`)
  so a provisioner's Identify (0x02) command makes the box you're about to
  provision visibly wink. Runs fire-and-forget inside Improv's Task.Supervisor,
  so `Process.sleep/1` here never blocks a GenServer loop.

  The Pi exposes the green activity LED at `/sys/class/leds/ACT` (`led0` on
  older kernels). We park its trigger, blink, and restore the original trigger
  (normally `mmc0`) even if the blink loop dies. On boards with no known
  activity LED this logs and returns — identification is best-effort.
  """

  require Logger

  @led_names ["ACT", "led0"]
  @leds_root "/sys/class/leds"

  # ~10 s of blinking at 4 Hz (125 ms half-period).
  @blink_half_period_ms 125
  @blink_toggles 80

  @doc """
  Blink the activity LED (~10 s at the defaults; blocking — run it in a Task).

  `opts` override the blink timing (`half_period_ms:`, `toggles:`) so host
  tests can run the full park/blink/restore cycle in milliseconds.
  """
  @spec blink_act_led(Path.t(), keyword()) :: :ok
  def blink_act_led(root \\ @leds_root, opts \\ []) do
    case find_led(root) do
      nil ->
        Logger.info("Identify requested — no activity LED on this board")

      led ->
        Logger.info("Identify requested — blinking #{led}")
        blink(led, opts)
    end

    :ok
  end

  defp find_led(root) do
    Enum.find_value(@led_names, fn name ->
      path = Path.join(root, name)
      if File.exists?(Path.join(path, "brightness")), do: path
    end)
  end

  defp blink(led, opts) do
    half_period_ms = Keyword.get(opts, :half_period_ms, @blink_half_period_ms)
    toggles = Keyword.get(opts, :toggles, @blink_toggles)

    original_trigger = current_trigger(led)
    write(led, "trigger", "none")

    try do
      max = max_brightness(led)

      for n <- 1..toggles do
        write(led, "brightness", if(rem(n, 2) == 1, do: max, else: "0"))
        Process.sleep(half_period_ms)
      end
    after
      write(led, "brightness", "0")
      if original_trigger, do: restore_trigger(led, original_trigger)
    end
  end

  # A failed restore leaves the LED dark on trigger "none" — invisible unless
  # logged (the blink itself already "worked" from the caller's perspective).
  defp restore_trigger(led, trigger) do
    case write(led, "trigger", trigger) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Identify: failed to restore #{led} trigger #{trigger}: #{inspect(reason)}"
        )
    end
  end

  # The active trigger is the [bracketed] entry of the trigger file.
  defp current_trigger(led) do
    with {:ok, content} <- File.read(Path.join(led, "trigger")),
         [_, trigger] <- Regex.run(~r/\[(\S+)\]/, content) do
      trigger
    else
      _ -> nil
    end
  end

  defp max_brightness(led) do
    case File.read(Path.join(led, "max_brightness")) do
      {:ok, s} -> String.trim(s)
      _ -> "1"
    end
  end

  defp write(led, file, value) do
    File.write(Path.join(led, file), value)
  end
end
