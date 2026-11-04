defmodule UniversalProxy.Cec.EnumerateTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.Cec.Enumerate

  # Lays out the sysfs shape vc4 produces on a Pi 4: two HDMI platform
  # devices, each with a CEC adapter and an ALSA card pointing at it, plus a
  # headphone card on another device and an adapter with no /dev node. As in
  # real sysfs, `/sys/class/<subsys>/<name>` is a symlink into
  # `/sys/devices/...` and its `device` link is relative to that real
  # directory.
  setup do
    root = Path.join(System.tmp_dir!(), "cec_enum_#{System.unique_integer([:positive])}")
    soc = Path.join(root, "sys/devices/platform/soc")
    cec = Path.join(root, "sys/class/cec")
    sound = Path.join(root, "sys/class/sound")
    dev = Path.join(root, "dev")

    File.mkdir_p!(cec)
    File.mkdir_p!(sound)
    File.mkdir_p!(dev)

    link = fn class_root, name, device_path ->
      subsys = Path.basename(class_root)
      real = Path.join([soc, device_path, subsys, name])
      File.mkdir_p!(real)
      File.ln_s!("../../../#{Path.basename(device_path)}", Path.join(real, "device"))

      File.ln_s!(
        "../../devices/platform/soc/#{device_path}/#{subsys}/#{name}",
        Path.join(class_root, name)
      )
    end

    link.(cec, "cec0", "fef00700.hdmi")
    link.(cec, "cec1", "fef05700.hdmi")
    link.(cec, "cec2", "fe00b840.mailbox")
    link.(sound, "card0", "fe00b840.mailbox/bcm2835-audio")
    link.(sound, "card1", "fef00700.hdmi")
    link.(sound, "card2", "fef05700.hdmi")
    File.touch!(Path.join(dev, "cec0"))
    File.touch!(Path.join(dev, "cec1"))

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok,
     opts: [
       class_root: cec,
       bus_root: Path.join(root, "sys/bus/cec/devices"),
       sound_sys_root: sound,
       dev_root: dev
     ],
     root: root,
     dev: dev,
     soc: soc}
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
             class_root: "/nonexistent/cec",
             bus_root: "/nonexistent/bus",
             sound_sys_root: "/nonexistent/sound",
             dev_root: "/nonexistent"
           ) == %{}
  end

  test "pairs by the resolved device node, not just its basename", %{
    opts: opts,
    dev: dev,
    soc: soc
  } do
    # A card on a different device that happens to share the HDMI node's
    # basename must not be paired with cec0.
    real = Path.join([soc, "fe9c0000.bus/fef00700.hdmi/sound/card3"])
    File.mkdir_p!(real)
    File.ln_s!("../../../fef00700.hdmi", Path.join(real, "device"))

    File.ln_s!(
      "../../devices/platform/soc/fe9c0000.bus/fef00700.hdmi/sound/card3",
      Path.join(opts[:sound_sys_root], "card3")
    )

    File.rm!(Path.join(opts[:sound_sys_root], "card1"))

    assert %{card_index: nil, hdmi_device: "fef00700.hdmi"} =
             Enumerate.list(opts)[Path.join(dev, "cec0")]
  end

  describe "bus layout (kernel 6.18, no /sys/class/cec)" do
    # `/sys/bus/cec/devices/cecN` -> `../../../devices/platform/soc/<hdmi>/cecN`;
    # the cec device dir has no `device` link, its parent is the HDMI node.
    defp bus_cec(root, soc, hdmi, name) do
      real = Path.join([soc, hdmi, name])
      File.mkdir_p!(real)
      bus = Path.join(root, "sys/bus/cec/devices")
      File.mkdir_p!(bus)
      File.ln_s!("../../../devices/platform/soc/#{hdmi}/#{name}", Path.join(bus, name))
    end

    defp sound_card(root, soc, hdmi, name) do
      real = Path.join([soc, hdmi, "sound", name])
      File.mkdir_p!(real)
      File.ln_s!("../../../#{hdmi}", Path.join(real, "device"))
      sound = Path.join(root, "sys/class/sound")
      File.mkdir_p!(sound)

      File.ln_s!(
        "../../devices/platform/soc/#{hdmi}/sound/#{name}",
        Path.join(sound, name)
      )
    end

    setup do
      root = Path.join(System.tmp_dir!(), "cec_bus_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "dev"))
      on_exit(fn -> File.rm_rf!(root) end)

      {:ok,
       root: root,
       soc: Path.join(root, "sys/devices/platform/soc"),
       opts: [
         class_root: Path.join(root, "sys/class/cec"),
         bus_root: Path.join(root, "sys/bus/cec/devices"),
         sound_sys_root: Path.join(root, "sys/class/sound"),
         dev_root: Path.join(root, "dev")
       ]}
    end

    test "pairs the adapter with the card on the same HDMI device", %{
      root: root,
      soc: soc,
      opts: opts
    } do
      bus_cec(root, soc, "3f902000.hdmi", "cec0")
      sound_card(root, soc, "3f902000.hdmi", "card1")
      File.touch!(Path.join(root, "dev/cec0"))

      dev = Path.join(root, "dev/cec0")

      assert Enumerate.list(opts) == %{
               dev => %{dev: dev, index: 0, hdmi_device: "3f902000.hdmi", card_index: 1}
             }
    end

    test "two adapters and two HDMI cards pair independently (Pi 4)", %{
      root: root,
      soc: soc,
      opts: opts
    } do
      bus_cec(root, soc, "fef00700.hdmi", "cec0")
      bus_cec(root, soc, "fef05700.hdmi", "cec1")
      sound_card(root, soc, "fef05700.hdmi", "card2")
      sound_card(root, soc, "fef00700.hdmi", "card1")
      File.touch!(Path.join(root, "dev/cec0"))
      File.touch!(Path.join(root, "dev/cec1"))

      result = Enumerate.list(opts)
      assert %{hdmi_device: "fef00700.hdmi", card_index: 1} = result[Path.join(root, "dev/cec0")]
      assert %{hdmi_device: "fef05700.hdmi", card_index: 2} = result[Path.join(root, "dev/cec1")]
    end

    test "an adapter in both layouts is listed once", %{root: root, soc: soc, opts: opts} do
      bus_cec(root, soc, "fef00700.hdmi", "cec0")
      sound_card(root, soc, "fef00700.hdmi", "card1")

      class = opts[:class_root]
      File.mkdir_p!(class)
      real = Path.join(soc, "fef00700.hdmi/cec/cec0")
      File.mkdir_p!(real)
      File.ln_s!("../../../fef00700.hdmi", Path.join(real, "device"))
      File.ln_s!("../../devices/platform/soc/fef00700.hdmi/cec/cec0", Path.join(class, "cec0"))
      File.touch!(Path.join(root, "dev/cec0"))

      dev = Path.join(root, "dev/cec0")

      assert Enumerate.list(opts) == %{
               dev => %{dev: dev, index: 0, hdmi_device: "fef00700.hdmi", card_index: 1}
             }
    end
  end
end
