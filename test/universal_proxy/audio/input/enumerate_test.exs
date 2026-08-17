defmodule UniversalProxy.Audio.Input.EnumerateTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Audio.Input.Enumerate

  describe "list_inputs/1 with synthesised filesystem" do
    @tag :tmp_dir
    test "returns %{} when /proc/asound/cards is missing", %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(proc_root)
      File.mkdir_p!(sys_root)

      assert Enumerate.list_inputs(proc_root: proc_root, sys_root: sys_root) == %{}
    end

    @tag :tmp_dir
    test "returns %{} when both roots are entirely missing", %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "no-proc")
      sys_root = Path.join(tmp_dir, "no-sys")

      assert Enumerate.list_inputs(proc_root: proc_root, sys_root: sys_root) == %{}
    end

    @tag :tmp_dir
    test "includes a capture-only card", %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))
      File.mkdir_p!(Path.join([sys_root, "card0", "device"]))
      File.mkdir_p!(Path.join(sys_root, "pcmC0D0c"))

      File.write!(Path.join([proc_root, "asound", "cards"]), """
       0 [Mic            ]: USB-Audio - USB Microphone
                            USB Microphone
      """)

      File.write!(Path.join([sys_root, "card0", "device", "uevent"]), """
      DRIVER=snd-usb-audio
      PRODUCT=046d/0a03/6e
      """)

      assert Enumerate.list_inputs(proc_root: proc_root, sys_root: sys_root) == %{
               {"USB Microphone", 0x046D, 0x0A03} => %{
                 name: "USB Microphone",
                 alsa_device: "plughw:0,0",
                 card_index: 0,
                 vid: 0x046D,
                 pid: 0x0A03,
                 usb_port: nil
               }
             }
    end

    @tag :tmp_dir
    test "excludes a playback-only card entirely", %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))
      File.mkdir_p!(Path.join([sys_root, "card0", "device"]))
      File.mkdir_p!(Path.join(sys_root, "pcmC0D0p"))

      File.write!(Path.join([proc_root, "asound", "cards"]), """
       0 [DAC            ]: USB-Audio - USB DAC
                            USB DAC
      """)

      File.write!(Path.join([sys_root, "card0", "device", "uevent"]), """
      DRIVER=snd-usb-audio
      PRODUCT=1d6b/0104/100
      """)

      assert Enumerate.list_inputs(proc_root: proc_root, sys_root: sys_root) == %{}
    end

    @tag :tmp_dir
    test "duplex card (both directions) uses the lowest capture device number",
         %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))
      File.mkdir_p!(Path.join([sys_root, "card0", "device"]))
      # Playback device 0, plus capture devices 2 and 0 — the lowest capture
      # device number (0) must win even though it's not the only capture dev.
      File.mkdir_p!(Path.join(sys_root, "pcmC0D0p"))
      File.mkdir_p!(Path.join(sys_root, "pcmC0D0c"))
      File.mkdir_p!(Path.join(sys_root, "pcmC0D2c"))

      File.write!(Path.join([proc_root, "asound", "cards"]), """
       0 [Duplex         ]: USB-Audio - USB Headset
                            USB Headset
      """)

      File.write!(Path.join([sys_root, "card0", "device", "uevent"]), """
      DRIVER=snd-usb-audio
      PRODUCT=0d8c/0014/100
      """)

      assert %{{"USB Headset", 0x0D8C, 0x0014} => info} =
               Enumerate.list_inputs(proc_root: proc_root, sys_root: sys_root)

      assert info.alsa_device == "plughw:0,0"
      assert info.card_index == 0
    end

    @tag :tmp_dir
    test "a non-USB internal card is keyed by card name", %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))
      File.mkdir_p!(Path.join([sys_root, "card0", "device"]))
      File.mkdir_p!(Path.join(sys_root, "pcmC0D0c"))

      File.write!(Path.join([proc_root, "asound", "cards"]), """
       0 [Onboard        ]: bcm2835-input - bcm2835 Input
                            bcm2835 Input
      """)

      # SoC cards have no PRODUCT= line (no USB VID/PID) and no `device`
      # symlink to a USB interface.
      File.write!(Path.join([sys_root, "card0", "device", "uevent"]), """
      DRIVER=bcm2835_audio
      OF_NAME=audio
      """)

      assert Enumerate.list_inputs(proc_root: proc_root, sys_root: sys_root) == %{
               {"bcm2835 Input", nil, nil} => %{
                 name: "bcm2835 Input",
                 alsa_device: "plughw:0,0",
                 card_index: 0,
                 vid: nil,
                 pid: nil,
                 usb_port: nil
               }
             }
    end

    @tag :tmp_dir
    test "tolerates missing/garbled uevent content", %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))
      File.mkdir_p!(Path.join([sys_root, "card0", "device"]))
      File.mkdir_p!(Path.join(sys_root, "pcmC0D0c"))

      File.write!(Path.join([proc_root, "asound", "cards"]), """
       0 [Weird          ]: USB-Audio - USB Weird Thing
                            USB Weird Thing
      """)

      File.write!(
        Path.join([sys_root, "card0", "device", "uevent"]),
        "\0\xFF not a uevent at all"
      )

      assert Enumerate.list_inputs(proc_root: proc_root, sys_root: sys_root) == %{
               {"USB Weird Thing", nil, nil} => %{
                 name: "USB Weird Thing",
                 alsa_device: "plughw:0,0",
                 card_index: 0,
                 vid: nil,
                 pid: nil,
                 usb_port: nil
               }
             }
    end

    @tag :tmp_dir
    test "same identity survives a hotplug index shuffle; alsa_device tracks the new index",
         %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))

      write_usb_capture_card(sys_root, 0, "1-1.3", "0bda/4e27/18")

      File.write!(Path.join([proc_root, "asound", "cards"]), """
       0 [Mic            ]: USB-Audio - USB Microphone
                            USB Microphone
      """)

      before = Enumerate.list_inputs(proc_root: proc_root, sys_root: sys_root)

      assert %{{"1-1.3", 0x0BDA, 0x4E27} => %{alsa_device: "plughw:0,0", card_index: 0}} =
               before

      # Simulate the same physical device re-enumerating as card1 after a
      # hotplug event (e.g. another card attached first on reboot).
      sys_root_2 = Path.join(tmp_dir, "sys2")
      write_usb_capture_card(sys_root_2, 1, "1-1.3", "0bda/4e27/18")

      File.write!(Path.join([proc_root, "asound", "cards"]), """
       1 [Mic            ]: USB-Audio - USB Microphone
                            USB Microphone
      """)

      after_shuffle = Enumerate.list_inputs(proc_root: proc_root, sys_root: sys_root_2)

      assert %{{"1-1.3", 0x0BDA, 0x4E27} => %{alsa_device: "plughw:1,0", card_index: 1}} =
               after_shuffle

      # Same key both times — identity is stable across the index shuffle.
      assert Map.keys(before) == Map.keys(after_shuffle)
    end
  end

  describe "safe/0" do
    test "returns a map without raising on the host" do
      assert is_map(Enumerate.safe())
    end

    @tag :tmp_dir
    test "swallows malformed /proc content and still returns a map", %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))
      File.mkdir_p!(sys_root)
      File.write!(Path.join([proc_root, "asound", "cards"]), "completely bogus content\n")

      assert Enumerate.list_inputs(proc_root: proc_root, sys_root: sys_root) == %{}
    end
  end

  # Builds a `cardN` + USB-interface-symlink + capture pcm node tree
  # identical in shape to `Audio.Enumerate`'s USB bus-path fixtures.
  defp write_usb_capture_card(sys_root, card_index, usb_port, product) do
    iface = Path.join([sys_root, "usbdev", usb_port, "#{usb_port}:1.0"])
    File.mkdir_p!(iface)
    File.write!(Path.join(iface, "uevent"), "DRIVER=snd-usb-audio\nPRODUCT=#{product}\n")

    File.mkdir_p!(Path.join(sys_root, "card#{card_index}"))

    File.ln_s!(
      "../usbdev/#{usb_port}/#{usb_port}:1.0",
      Path.join([sys_root, "card#{card_index}", "device"])
    )

    File.mkdir_p!(Path.join(sys_root, "pcmC#{card_index}D0c"))
  end
end
