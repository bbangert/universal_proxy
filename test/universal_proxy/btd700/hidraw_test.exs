defmodule UniversalProxy.BTD700.HidrawTest do
  use ExUnit.Case, async: true

  alias UniversalProxy.BTD700.Hidraw

  @usb_port "1-1.3.1"

  # Report descriptors below are synthetic (no full byte-for-byte dump was
  # captured during the hardware probe — see research/hw-probe.md), but the
  # bytes that matter for selection are the ones the probe *did* confirm:
  # usage page 0xFFA2 (`06 A2 FF`) and report ID 0x34 (`85 34`). Each
  # fixture wraps those markers (or omits them) in a minimal, realistic-
  # looking HID collection so the matcher has to actually parse content,
  # not just check fixture length.

  # Consumer-control collection (media keys) — usage page 0x0C, no vendor
  # marker anywhere. Modeled on hidraw0's pre-correction summary in
  # hw-probe.md ("usage page 0x0C (Consumer)").
  @consumer_descriptor <<0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x01, 0x15, 0x00, 0x25, 0x01,
                         0xC0>>

  # Unrelated vendor collection (hidraw1 in hw-probe.md — usage page
  # 0xFF00, a *different* vendor page, no report ID 0x34 anywhere).
  @other_vendor_descriptor <<0x06, 0x00, 0xFF, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x05, 0xC0>>

  # The real control collection: usage page 0xFFA2 + report ID 0x34.
  @control_descriptor <<0x05, 0x0C, 0x09, 0x01, 0xA1, 0x01, 0x85, 0x01, 0xC0, 0x06, 0xA2, 0xFF,
                        0x09, 0x01, 0xA1, 0x01, 0x85, 0x34, 0x75, 0x08, 0x95, 0x3C, 0x81, 0x02,
                        0xC0>>

  defp write_hidraw(root, name, phys, descriptor) do
    device_dir = Path.join([root, name, "device"])
    File.mkdir_p!(device_dir)

    File.write!(Path.join(device_dir, "uevent"), """
    DRIVER=hid-generic
    HID_ID=0003:00003542:00003001
    HID_NAME=Sennheiser BTD 700
    HID_PHYS=#{phys}
    HID_UNIQ=09B88CA980031BAB3C08
    """)

    File.write!(Path.join(device_dir, "report_descriptor"), descriptor)
  end

  defp tmp_root do
    path =
      Path.join(System.tmp_dir!(), "btd700_hidraw_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  describe "control_node/2" do
    test "picks the node whose descriptor carries both the 0xFFA2 usage page and report ID 0x34" do
      root = tmp_root()
      write_hidraw(root, "hidraw0", "usb-3f980000.usb-1.3.1/input0", @consumer_descriptor)
      write_hidraw(root, "hidraw1", "usb-3f980000.usb-1.3.1/input1", @other_vendor_descriptor)
      write_hidraw(root, "hidraw2", "usb-3f980000.usb-1.3.1/input2", @control_descriptor)

      assert Hidraw.control_node(@usb_port, hidraw_class_dir: root) == {:ok, "/dev/hidraw2"}
    end

    test "the control collection can share a node with the consumer-keys collection" do
      # Live probe correction (hw-probe.md): both collections can live on
      # the SAME hidraw node, one descriptor. Selection must still work.
      root = tmp_root()
      combined = @consumer_descriptor <> @control_descriptor
      write_hidraw(root, "hidraw0", "usb-3f980000.usb-1.3.1/input0", combined)

      assert Hidraw.control_node(@usb_port, hidraw_class_dir: root) == {:ok, "/dev/hidraw0"}
    end

    test "never matches by index alone — a lower-numbered node without the markers loses" do
      root = tmp_root()
      write_hidraw(root, "hidraw0", "usb-3f980000.usb-1.3.1/input0", @other_vendor_descriptor)
      write_hidraw(root, "hidraw1", "usb-3f980000.usb-1.3.1/input1", @control_descriptor)

      assert Hidraw.control_node(@usb_port, hidraw_class_dir: root) == {:ok, "/dev/hidraw1"}
    end

    test "bus path is a prefix match on the port path, not the whole HID_PHYS string" do
      root = tmp_root()
      # A different controller-id prefix than the fixture above — only the
      # trailing port-path segment has to match.
      write_hidraw(root, "hidraw0", "usb-0000:00:14.0-1.3.1/input1", @control_descriptor)

      assert Hidraw.control_node(@usb_port, hidraw_class_dir: root) == {:ok, "/dev/hidraw0"}
    end

    test "a shorter sibling port path never falsely prefix-matches a deeper one" do
      root = tmp_root()
      # This node belongs to port "1-1.3", not "1-1.3.1" — must not match.
      write_hidraw(root, "hidraw0", "usb-3f980000.usb-1.3/input0", @control_descriptor)

      assert Hidraw.control_node(@usb_port, hidraw_class_dir: root) == {:error, :not_found}
    end

    test "another device's matching descriptor at a different bus path is not selected" do
      root = tmp_root()
      write_hidraw(root, "hidraw0", "usb-3f980000.usb-1.3.2/input0", @control_descriptor)

      assert Hidraw.control_node(@usb_port, hidraw_class_dir: root) == {:error, :not_found}
    end

    test "{:error, :not_found} when no candidate matches" do
      root = tmp_root()
      write_hidraw(root, "hidraw0", "usb-3f980000.usb-1.3.1/input0", @consumer_descriptor)
      write_hidraw(root, "hidraw1", "usb-3f980000.usb-1.3.1/input1", @other_vendor_descriptor)

      assert Hidraw.control_node(@usb_port, hidraw_class_dir: root) == {:error, :not_found}
    end

    test "{:error, :not_found} when the sysfs root doesn't exist at all" do
      assert Hidraw.control_node(@usb_port, hidraw_class_dir: "/nonexistent/path") ==
               {:error, :not_found}
    end
  end
end
