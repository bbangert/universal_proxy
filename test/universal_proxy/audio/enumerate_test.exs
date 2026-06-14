defmodule UniversalProxy.Audio.EnumerateTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Audio.Enumerate

  @sample_cards """
   0 [Headphones     ]: bcm2835_headphonE - bcm2835 Headphones
                        bcm2835 Headphones
   1 [vc4hdmi        ]: vc4-hdmi - vc4-hdmi
                        vc4-hdmi
  """

  describe "parse_cards/1" do
    test "extracts card index + long name from real-world output" do
      assert Enumerate.parse_cards(@sample_cards) == [
               {0, "bcm2835 Headphones"},
               {1, "vc4-hdmi"}
             ]
    end

    test "returns [] on empty input" do
      assert Enumerate.parse_cards("") == []
    end

    test "ignores garbage lines without raising" do
      garbage = """
      not a card header
       0 [missing-closing-bracket: foo - bar
                         indented continuation
      ###
      """

      assert Enumerate.parse_cards(garbage) == []
    end

    test "handles trailing whitespace in long name" do
      input = " 0 [Foo    ]: drv - Built-in Card   \n"
      assert Enumerate.parse_cards(input) == [{0, "Built-in Card"}]
    end
  end

  describe "list_outputs/1 with synthesised filesystem" do
    @tag :tmp_dir
    test "returns %{} when /proc/asound/cards is missing", %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(proc_root)
      File.mkdir_p!(sys_root)

      assert Enumerate.list_outputs(proc_root: proc_root, sys_root: sys_root) == %{}
    end

    @tag :tmp_dir
    test "parses cards into the expected key-tuple map", %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))
      File.mkdir_p!(sys_root)
      File.write!(Path.join([proc_root, "asound", "cards"]), @sample_cards)

      outputs = Enumerate.list_outputs(proc_root: proc_root, sys_root: sys_root)

      assert outputs == %{
               {"bcm2835 Headphones", nil, nil} => %{
                 card_index: 0,
                 alsa_device: "plughw:0,0",
                 card_name: "bcm2835 Headphones",
                 usb_port: nil
               },
               {"vc4-hdmi", nil, nil} => %{
                 card_index: 1,
                 alsa_device: "plughw:1,0",
                 card_name: "vc4-hdmi",
                 usb_port: nil
               }
             }
    end

    @tag :tmp_dir
    test "lifts vendor/product IDs from sys/class/sound/cardN/device/uevent",
         %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))
      File.mkdir_p!(Path.join([sys_root, "card0", "device"]))

      File.write!(Path.join([proc_root, "asound", "cards"]), """
       0 [USB            ]: USB-Audio - USB Audio Gadget
                            USB Audio Gadget
      """)

      File.write!(Path.join([sys_root, "card0", "device", "uevent"]), """
      DRIVER=snd-usb-audio
      PRODUCT=1d6b/0104/100
      """)

      assert Enumerate.list_outputs(proc_root: proc_root, sys_root: sys_root) == %{
               {"USB Audio Gadget", 0x1D6B, 0x0104} => %{
                 card_index: 0,
                 alsa_device: "plughw:0,0",
                 card_name: "USB Audio Gadget",
                 usb_port: nil
               }
             }
    end

    @tag :tmp_dir
    test "lifts the USB bus path from the card's device symlink", %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))

      # The real USB interface dir the card's `device` symlink points at; the
      # bus path "1-1.3" is the interface segment ("1-1.3:1.0") before the colon.
      iface = Path.join([sys_root, "usbdev", "1-1.3", "1-1.3:1.0"])
      File.mkdir_p!(iface)

      File.write!(Path.join(iface, "uevent"), """
      DRIVER=snd-usb-audio
      PRODUCT=0bda/4e27/18
      """)

      File.mkdir_p!(Path.join(sys_root, "card0"))
      File.ln_s!("../usbdev/1-1.3/1-1.3:1.0", Path.join([sys_root, "card0", "device"]))

      File.write!(Path.join([proc_root, "asound", "cards"]), """
       0 [Adapter        ]: USB-Audio - USB SPDIF Adapter
                            USB SPDIF Adapter
      """)

      assert Enumerate.list_outputs(proc_root: proc_root, sys_root: sys_root) == %{
               {"USB SPDIF Adapter", 0x0BDA, 0x4E27} => %{
                 card_index: 0,
                 alsa_device: "plughw:0,0",
                 card_name: "USB SPDIF Adapter",
                 usb_port: "1-1.3"
               }
             }
    end

    @tag :tmp_dir
    test "tolerates malformed uevent (no PRODUCT line) by emitting nil VID/PID",
         %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))
      File.mkdir_p!(Path.join([sys_root, "card0", "device"]))

      File.write!(Path.join([proc_root, "asound", "cards"]), """
       0 [SoC            ]: bcm2835 - bcm2835 Headphones
                            bcm2835 Headphones
      """)

      File.write!(Path.join([sys_root, "card0", "device", "uevent"]), """
      DRIVER=bcm2835_audio
      OF_NAME=audio
      """)

      assert Enumerate.list_outputs(proc_root: proc_root, sys_root: sys_root) == %{
               {"bcm2835 Headphones", nil, nil} => %{
                 card_index: 0,
                 alsa_device: "plughw:0,0",
                 card_name: "bcm2835 Headphones",
                 usb_port: nil
               }
             }
    end
  end

  describe "safe/0" do
    test "returns %{} (or a map) without raising on the host" do
      result = Enumerate.safe()
      assert is_map(result)
    end

    @tag :tmp_dir
    test "swallows malformed /proc content and still returns a map", %{tmp_dir: tmp_dir} do
      proc_root = Path.join(tmp_dir, "proc")
      sys_root = Path.join(tmp_dir, "sys")
      File.mkdir_p!(Path.join(proc_root, "asound"))
      File.mkdir_p!(sys_root)
      File.write!(Path.join([proc_root, "asound", "cards"]), "completely bogus content\n")

      assert Enumerate.list_outputs(proc_root: proc_root, sys_root: sys_root) == %{}
    end
  end
end
