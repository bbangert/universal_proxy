defmodule UniversalProxy.Cec.EnumerateTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Cec.Enumerate

  # Lays out the sysfs shape vc4 produces on a Pi 4: two HDMI platform
  # devices, each with a CEC adapter and an ALSA card pointing at it, plus a
  # headphone card on another device and an adapter with no /dev node.
  setup do
    root = Path.join(System.tmp_dir!(), "cec_enum_#{System.unique_integer([:positive])}")
    devices = Path.join(root, "sys/devices/platform/soc")
    cec = Path.join(root, "sys/class/cec")
    sound = Path.join(root, "sys/class/sound")
    dev = Path.join(root, "dev")

    for d <- ["fef00700.hdmi", "fef05700.hdmi", "fe00b840.mailbox"],
        do: File.mkdir_p!(Path.join(devices, d))

    File.mkdir_p!(cec)
    File.mkdir_p!(sound)
    File.mkdir_p!(dev)

    link = fn class_dir, device ->
      File.mkdir_p!(class_dir)
      File.ln_s!("../../devices/platform/soc/#{device}", Path.join(class_dir, "device"))
    end

    link.(Path.join(cec, "cec0"), "fef00700.hdmi")
    link.(Path.join(cec, "cec1"), "fef05700.hdmi")
    link.(Path.join(cec, "cec2"), "fe00b840.mailbox")
    link.(Path.join(sound, "card0"), "fe00b840.mailbox")
    link.(Path.join(sound, "card1"), "fef00700.hdmi")
    link.(Path.join(sound, "card2"), "fef05700.hdmi")
    File.touch!(Path.join(dev, "cec0"))
    File.touch!(Path.join(dev, "cec1"))

    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, opts: [sys_root: cec, sound_sys_root: sound, dev_root: dev], dev: dev}
  end

  test "pairs each adapter with the ALSA card on the same HDMI device", %{opts: opts, dev: dev} do
    assert Enumerate.list(opts) == %{
             Path.join(dev, "cec0") => %{
               dev: Path.join(dev, "cec0"),
               index: 0,
               hdmi_device: "fef00700.hdmi",
               card_index: 1
             },
             Path.join(dev, "cec1") => %{
               dev: Path.join(dev, "cec1"),
               index: 1,
               hdmi_device: "fef05700.hdmi",
               card_index: 2
             }
           }
  end

  test "an adapter without a /dev node is skipped and a missing sysfs root is empty", %{
    opts: opts
  } do
    refute Map.has_key?(Enumerate.list(opts), Path.join(opts[:dev_root], "cec2"))

    assert Enumerate.list(
             sys_root: "/nonexistent/cec",
             sound_sys_root: "/nonexistent/sound",
             dev_root: "/nonexistent"
           ) == %{}
  end
end
