defmodule UniversalProxyWeb.OverviewLiveTest do
  @moduledoc """
  Focused tests for the audio-outputs summary row that was layered onto
  the Overview tab in Phase 4. The full-page smoke check stays in
  [render_smoke_test.exs](render_smoke_test.exs); this file drives the
  audio PubSub plumbing.
  """

  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import UniversalProxy.AudioFixtures

  alias UniversalProxy.StorageStub
  alias UniversalProxyWeb.OverviewLive

  @endpoint UniversalProxyWeb.Endpoint
  @pubsub UniversalProxy.PubSub

  @hp_key UniversalProxy.AudioFixtures.hp_key()

  setup do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "USB Bluetooth row is keyed by its physical USB port, not its hci name",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    # A USB dongle the kernel resolved to receptacle 1-1.1.2. The Overview
    # hardware table should present it by that physical port (matching how
    # the Bluetooth page reads), never by the placeless "hci1" sysfs name.
    Phoenix.PubSub.broadcast(
      @pubsub,
      "bluetooth:radios",
      {:bluetooth_radios,
       [
         %{
           hci: "hci1",
           bus: :usb,
           port: "1-1.1.2",
           detail: "USB 2.0 · port 1-1.1.2",
           chip: "Realtek RTL8761B",
           bt_version: "5.1",
           ble?: true,
           bredr?: true,
           name: "ASUS USB-BT500",
           address: nil,
           in_use?: false
         }
       ]}
    )

    html = render(view)
    assert html =~ "1-1.1.2"
    assert html =~ "Bluetooth proxy"
    refute html =~ "hci1"
  end

  test "Overview omits the audio card when no outputs are present", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")
    # Audio summary card is gated on a non-empty list, and the
    # test-env NullEnumerate keeps the Audio.Server list empty.
    refute html =~ "Audio outputs"
  end

  test "Overview renders an audio row when :sendspin_output_added arrives", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    html = render(view)
    assert html =~ "Audio outputs"
    assert html =~ "Headphones"
    assert html =~ "plughw:0,0"
    # Default badge for enabled-but-no-event-yet output. Audio + Overview
    # collapse to one vocabulary; "Searching" is the warning-tinted
    # "we'd like to be streaming but nothing has connected" label.
    assert html =~ "Searching"
  end

  test "a connected Bluetooth output renders in the audio summary", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    bt =
      sample_output(%{
        key: {"AA:BB:CC:DD:EE:FF", nil, nil},
        card_index: nil,
        alsa_device: "bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp",
        card_name: "Bluetooth A2DP",
        friendly_name: "Kitchen Speaker"
      })

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, bt}
    )

    html = render(view)
    assert html =~ "Audio outputs"
    assert html =~ "Kitchen Speaker"
    assert html =~ "bluealsa:DEV=AA:BB:CC:DD:EE:FF"
  end

  test "binary events progress the badge through Searching → Connected → Streaming",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    assert render(view) =~ "Searching"

    # WebSocket up but no audio yet → "Connected", not "Streaming".
    # The Sendspin client holds the socket open between songs, so this
    # is the long-lived idle-but-attached state.
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "connected"}}
    )

    html = render(view)
    assert html =~ "Connected"
    refute html =~ ">Streaming<"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key,
       %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
    )

    assert render(view) =~ "Streaming"
  end

  test "stream_end while still connected drops the badge back to Connected", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "connected"}}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key,
       %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
    )

    assert render(view) =~ "Streaming"

    # The exact bug PR #41 fixes — track ends, server keeps the
    # WebSocket open, badge must NOT stay on "Streaming".
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "stream_end"}}
    )

    html = render(view)
    assert html =~ "Connected"
    refute html =~ ">Streaming<"
  end

  test "disconnected clears the stream snapshot so badge can't read Streaming",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    # Race scenario: server pushed `stream_start`, then the socket
    # dropped before `stream_end`. The disconnected handler must clear
    # the cached stream — otherwise the badge would read "Streaming"
    # right up until the next `stream_end`, which never arrives.
    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "connected"}}
    )

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key,
       %{event: "stream_start", codec: "opus", sample_rate: 48_000, bit_depth: 16, channels: 2}}
    )

    assert render(view) =~ "Streaming"

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:state",
      {:sendspin_state, @hp_key, %{event: "disconnected"}}
    )

    html = render(view)
    assert html =~ "Searching"
    refute html =~ ">Streaming<"
  end

  test "Manage link points at /audio", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Phoenix.PubSub.broadcast(
      @pubsub,
      "sendspin:output_added",
      {:sendspin_output_added, sample_output()}
    )

    assert render(view) =~ ~s|href="/audio"|
  end

  describe "capture inputs in Connected hardware" do
    test "a capture-only input appears in Connected hardware but not the outputs card",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:input_added",
        {:sendspin_input_added, sample_input(%{friendly_name: "CUBILUX Line-in"})}
      )

      html = render(view)
      # It's a hardware device, so it must show in the topology table…
      assert html =~ "CUBILUX Line-in"
      assert html =~ "Audio input"
      # …but the outputs-only "Audio outputs" card must stay hidden (no outputs).
      refute html =~ "Audio outputs"
    end

    test ":sendspin_input_removed drops the input row again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:input_added",
        {:sendspin_input_added, sample_input(%{friendly_name: "CUBILUX Line-in"})}
      )

      assert render(view) =~ "CUBILUX Line-in"

      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:input_removed",
        {:sendspin_input_removed, %{key: input_key()}}
      )

      refute render(view) =~ "CUBILUX Line-in"
    end

    test "a duplex device (output + input, same key) renders as its output, not an input",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      dup_key = {"1-1.2", 0x1234, 0x5678}

      # Same key surfaces on both halves of the subsystem (playback + capture).
      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:output_added",
        {:sendspin_output_added,
         sample_output(%{
           key: dup_key,
           card_index: 2,
           usb_port: "1-1.2",
           card_name: "Duplex DAC",
           friendly_name: "Duplex DAC"
         })}
      )

      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:input_added",
        {:sendspin_input_added,
         sample_input(%{
           key: dup_key,
           usb_port: "1-1.2",
           name: "Duplex DAC",
           friendly_name: "Duplex DAC"
         })}
      )

      html = render(view)
      # Output wins the key-dedupe: the row is a "Sound card", and the input
      # half never spawns a separate "Audio input" row for the same device.
      assert html =~ "Duplex DAC"
      assert html =~ "Sound card"
      refute html =~ "Audio input"
    end

    test "a duplex device capturing with no output stream reads as in-use in its row",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      dup_key = {"1-1.2", 0x1234, 0x5678}

      # Output half: connected but NOT streaming (no `:stream`) — on its own the
      # row would read "Connected", never "In use".
      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:output_added",
        {:sendspin_output_added,
         sample_output(%{
           key: dup_key,
           card_index: 2,
           usb_port: "1-1.2",
           card_name: "Duplex DAC",
           friendly_name: "Duplex DAC",
           connection: :connected,
           stream: nil
         })}
      )

      # Input half of the same device is actively capturing.
      Phoenix.PubSub.broadcast(
        @pubsub,
        "sendspin:input_added",
        {:sendspin_input_added,
         sample_input(%{
           key: dup_key,
           usb_port: "1-1.2",
           name: "Duplex DAC",
           friendly_name: "Duplex DAC",
           status: :streaming
         })}
      )

      html = render(view)
      # Output presentation is kept (a "Sound card" row), but the merged capture
      # signal surfaces as "In use" rather than the output-only "Connected".
      assert html =~ "Duplex DAC"
      assert html =~ "Sound card"
      assert html =~ "In use"
    end
  end

  # The drive row, drawer and folder chooser are driven exactly as the
  # subsystem drives them: a full state map broadcast on "storage:state".
  # Writes go through a stubbed façade (`StorageStub`) — the real ones shell
  # out to `mkfs.ext4`/`umount` against the device path they are handed, so
  # they must never run against the test host's own disks.
  describe "USB storage drive" do
    @drive_key {"1-1.3", "0781", "55af"}
    @second_key {"1-1.4", "0781", "55af"}
    @password "test-only-password"

    setup do
      StorageStub.install(self(), folders: %{"/" => ["backups", "media"], "backups" => []})
      :ok
    end

    defp drive(opts \\ []) do
      %{
        name: Keyword.get(opts, :name, "sda"),
        dev_path: Keyword.get(opts, :dev_path, "/dev/sda"),
        size_bytes: 1_000_204_886_016,
        slot_sub: Keyword.get(opts, :slot_sub, "1-1.3"),
        vendor_id: 0x0781,
        product_id: 0x55AF,
        partitions: [],
        key: Keyword.get(opts, :key, @drive_key),
        fs_type: Keyword.get(opts, :fs_type, :exfat)
      }
    end

    defp mount(opts \\ []) do
      %{
        device: Keyword.get(opts, :device, "/dev/sda"),
        fs_type: Keyword.get(opts, :fs_type, :exfat),
        mode: Keyword.get(opts, :mode, :read_write),
        point: "/run/usb-backup",
        stale?: Keyword.get(opts, :stale?, false)
      }
    end

    defp storage_state(opts \\ []) do
      %{
        drives: Keyword.get(opts, :drives, [drive()]),
        mount: Keyword.get(opts, :mount, mount()),
        share: Keyword.get(opts, :share, :off),
        share_folder: Keyword.get(opts, :share_folder, "/"),
        capacity:
          Keyword.get(opts, :capacity, %{
            total_bytes: 1_000_204_886_016,
            used_bytes: 620_000_000_000,
            free_bytes: 380_204_886_016,
            used_pct: 62
          })
      }
    end

    defp push_storage(state) do
      Phoenix.PubSub.broadcast(@pubsub, "storage:state", {:storage_state, state})
    end

    defp open_drawer(view, device \\ "/dev/sda") do
      view |> element("tr[phx-value-device='#{device}']") |> render_click()
    end

    test "a mounted drive renders as a USB storage row", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")
      refute html =~ "USB storage"

      push_storage(storage_state())

      html = render(view)
      assert html =~ "USB storage"
      assert html =~ "USB drive"
      # USB ids + decimal-GB size, and the bus path it enumerated on.
      assert html =~ "0781:55AF"
      assert html =~ "1000 GB"
      assert html =~ "1-1.3"
      assert html =~ "Mounted"
      assert html =~ "Not shared"
    end

    test "a running share reads as Shared, claimed by Home Assistant", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      push_storage(storage_state(share: :running))

      html = render(view)
      assert html =~ "Shared"
      assert html =~ "Home Assistant backups"
    end

    test "an ejected (unmounted) drive reads as Unmounted", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      push_storage(storage_state(mount: nil, capacity: nil))

      assert render(view) =~ "Unmounted"
    end

    test "clicking the row opens the drive drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())

      html = open_drawer(view)
      assert html =~ "Danger zone"
      assert html =~ "Format as ext4"
      assert html =~ "Safe eject"
      assert html =~ "/dev/sda"
      assert html =~ "mounted read-write"
      assert html =~ "62%"
    end

    test "a non-journalled filesystem carries the format-to-ext4 advice", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())

      html = open_drawer(view)
      assert html =~ "exFAT"
      assert html =~ "Not journalled — format to ext4 recommended for backups."
    end

    test "an ext4 drive gets no journalling warning", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      push_storage(storage_state(drives: [drive(fs_type: :ext4)], mount: mount(fs_type: :ext4)))

      html = open_drawer(view)
      assert html =~ "ext4"
      refute html =~ "Not journalled"
    end

    test "a share that failed to start says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :error))

      html = open_drawer(view)
      assert html =~ "Share error"
      assert html =~ "Share failed to start — retrying."
    end

    test "the share toggle calls the façade with the drive key", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      view |> element("button[phx-click='drive_toggle_share']") |> render_click()

      assert_receive {:storage_call, :set_share_enabled, [@drive_key, true]}
    end

    test "toggling an already-running share turns it off", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :running))
      open_drawer(view)

      view |> element("button[phx-click='drive_toggle_share']") |> render_click()

      assert_receive {:storage_call, :set_share_enabled, [@drive_key, false]}
    end

    test "an unavailable subsystem flashes instead of crashing", %{conn: conn} do
      StorageStub.put_replies(%{set_share_enabled: {:error, :unavailable}})
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      html = view |> element("button[phx-click='drive_toggle_share']") |> render_click()
      assert html =~ "Storage subsystem unavailable."
    end

    test "the password is absent from the DOM until Reveal, and gone again after close",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :running))

      html = open_drawer(view)
      # Credentials section is rendered, but the secret is not in it.
      assert html =~ "Username"
      assert html =~ "Password"
      refute html =~ @password

      html = view |> element("button[phx-click='drive_reveal_password']") |> render_click()
      assert html =~ @password
      assert html =~ "Hide"

      view |> element("button[phx-click='close_drive_drawer']") |> render_click()
      html = open_drawer(view)
      refute html =~ @password
      assert html =~ "Reveal"
    end

    test "copying the password never renders it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :running))
      open_drawer(view)

      html = view |> element("button[phx-click='drive_copy_password']") |> render_click()

      assert html =~ "Copied"
      refute html =~ @password
    end

    test "regenerating the password arms first, then rotates and re-masks", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :running))
      open_drawer(view)

      # Reveal first, so the re-mask after rotation is observable.
      assert view |> element("button[phx-click='drive_reveal_password']") |> render_click() =~
               @password

      html = view |> element("button[phx-value-action='regen']") |> render_click()
      assert html =~ "Regenerating invalidates the old credential in Home Assistant immediately."
      refute_receive {:storage_call, :rotate_password, _}

      html = view |> element("button[phx-click='drive_regenerate_password']") |> render_click()
      assert_receive {:storage_call, :rotate_password, []}
      assert html =~ "Password regenerated. Update the credential in Home Assistant."
      refute html =~ @password
    end

    test "format needs a second, drive-naming confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      html = view |> element("button[phx-value-action='format']") |> render_click()
      assert html =~ "Erase everything on USB drive (/dev/sda) and format it as ext4?"
      refute_receive {:storage_call, :format_drive, _}

      view |> element("button[phx-click='drive_format']") |> render_click()
      # The drive KEY goes over the façade, never a device path: the
      # subsystem decides which device `mkfs` is pointed at.
      assert_receive {:storage_call, :format_drive, [@drive_key, _label]}
      # The format runs in a supervised task; its result clears the busy flag.
      assert render(view) =~ "Drive formatted as ext4."
    end

    test "a drive with no bus path formats by its nil key", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(drives: [drive(key: nil)]))
      open_drawer(view)

      view |> element("button[phx-value-action='format']") |> render_click()
      view |> element("button[phx-click='drive_format']") |> render_click()

      assert_receive {:storage_call, :format_drive, [nil, _label]}
    end

    # The two-step confirmation is server-held state, so a confirm event
    # that arrives without it — a crafted socket message, or a stale
    # button — must not act. The confirm buttons don't exist in the
    # unarmed markup, so these push the events directly.
    test "an unarmed format confirmation does nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      html = render_click(view, "drive_format", %{})

      refute_receive {:storage_call, :format_drive, _}
      assert html =~ "Confirm that action first."
      refute html =~ "Formatting…"
    end

    test "an unarmed eject confirmation does nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      html = render_click(view, "drive_eject", %{})

      refute_receive {:storage_call, :eject, _}
      assert html =~ "Confirm that action first."
      refute html =~ "safe to unplug"
    end

    # Disabling the Eject button in the markup is not a check: `drive_arm`
    # takes any action, so a crafted confirm can arrive on a socket whose
    # drawer is showing a second drive. Ejecting the FIRST drive there
    # would be an eject the user never asked for.
    test "a crafted eject on a second drive's drawer ejects nothing", %{conn: conn} do
      second = drive(name: "sdb", dev_path: "/dev/sdb", slot_sub: "1-1.4", key: @second_key)

      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(drives: [drive(), second]))
      open_drawer(view, "/dev/sdb")

      render_click(view, "drive_arm", %{"action" => "eject"})
      html = render_click(view, "drive_eject", %{})

      refute_receive {:storage_call, :eject, _}
      refute html =~ "safe to unplug"
    end

    # `mkfs` blocks Storage.Server for its whole run, so a concurrent
    # eject would queue behind it server-side; the drawer refuses it up
    # front rather than leaving the user with a queued surprise.
    test "a crafted eject while a format is in flight does nothing", %{conn: conn} do
      StorageStub.put_replies(%{format_drive: {:block, :ok}})

      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      view |> element("button[phx-value-action='format']") |> render_click()
      html = view |> element("button[phx-click='drive_format']") |> render_click()
      assert html =~ "Formatting…"
      assert_receive {:storage_blocked, :format_drive, task}

      render_click(view, "drive_arm", %{"action" => "eject"})
      html = render_click(view, "drive_eject", %{})

      refute_receive {:storage_call, :eject, _}
      refute html =~ "safe to unplug"

      send(task, :release)
    end

    # A crafted (or stale) re-arm while a format is already in flight must
    # not start a second one. The two would not race — `Storage.Server`
    # serializes them — but the FIRST result would clear the busy flag and
    # re-enable Format and Eject while the second `mkfs` was still writing.
    test "a crafted re-arm during an in-flight format starts no second format", %{conn: conn} do
      StorageStub.put_replies(%{format_drive: {:block, :ok}})

      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      view |> element("button[phx-value-action='format']") |> render_click()

      assert view |> element("button[phx-click='drive_format']") |> render_click() =~
               "Formatting…"

      assert_receive {:storage_blocked, :format_drive, task}
      # Drain the first call so the refutation below can only see a second.
      assert_received {:storage_call, :format_drive, _}

      # The arm is refused outright, so the confirm never even sees an
      # armed drawer — and the confirm refuses on its own account too.
      assert render_click(view, "drive_arm", %{"action" => "format"}) =~
               "A format is already running."

      html = render_click(view, "drive_format", %{})

      assert html =~ "A format is already running."
      refute_receive {:storage_call, :format_drive, _}, 50
      # And the one format that IS running still owns the busy flag.
      assert html =~ "Formatting…"

      send(task, :release)
    end

    # The busy flag belongs to the task that set it: a result from a task
    # this socket no longer tracks must not clear it.
    test "a format result from an untracked task is ignored", %{conn: conn} do
      StorageStub.put_replies(%{format_drive: {:block, :ok}})

      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      view |> element("button[phx-value-action='format']") |> render_click()

      assert view |> element("button[phx-click='drive_format']") |> render_click() =~
               "Formatting…"

      assert_receive {:storage_blocked, :format_drive, task}

      # This test process is not the task that owns the format.
      send(view.pid, {:storage_format_result, self(), "/dev/sda", :ok})

      html = render(view)
      assert html =~ "Formatting…"
      refute html =~ "Drive formatted as ext4."

      # The owning task's result is the one that ends it.
      send(view.pid, {:storage_format_result, task, "/dev/sda", :ok})

      html = render(view)
      refute html =~ "Formatting…"
      assert html =~ "Drive formatted as ext4."

      send(task, :release)
    end

    # A call timeout is the one format outcome that is not an outcome:
    # `Storage.Server` blocks its whole loop inside `mkfs.ext4`, so the
    # device may still be being written when the caller gives up.
    test "a format timeout keeps the drawer busy until the subsystem reports back",
         %{conn: conn} do
      # Blocking the façade is what makes the busy flag observable while
      # the format is still in flight.
      StorageStub.put_replies(%{format_drive: {:block, :ok}})

      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      view |> element("button[phx-value-action='format']") |> render_click()

      assert view |> element("button[phx-click='drive_format']") |> render_click() =~
               "Formatting…"

      assert_receive {:storage_blocked, :format_drive, task}

      # The task's result, delivered from here so the assertion cannot race
      # the façade call: the format timed out, the server is still wedged.
      send(view.pid, {:storage_format_result, task, "/dev/sda", {:error, :timeout}})

      html = render(view)
      assert html =~ "Formatting…"
      assert html =~ "Still working"

      # And the actions stay refused, not just visually disabled.
      render_click(view, "drive_arm", %{"action" => "eject"})
      render_click(view, "drive_eject", %{})
      refute_receive {:storage_call, :eject, _}

      # A broadcast is proof the server's loop is free again: nothing can
      # be published while a format runs inside its handle_call.
      push_storage(storage_state())
      refute render(view) =~ "Formatting…"

      send(task, :release)
    end

    test "a format failure that is not a timeout clears the busy flag at once", %{conn: conn} do
      StorageStub.put_replies(%{format_drive: {:block, :ok}})

      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      view |> element("button[phx-value-action='format']") |> render_click()

      assert view |> element("button[phx-click='drive_format']") |> render_click() =~
               "Formatting…"

      assert_receive {:storage_blocked, :format_drive, task}

      # Any other error means the server answered — it is not busy.
      send(view.pid, {:storage_format_result, task, "/dev/sda", {:error, :unknown_drive}})

      html = render(view)
      refute html =~ "Formatting…"
      assert html =~ "That drive is no longer attached."

      send(task, :release)
    end

    test "a busy filesystem is reported, not called safe to unplug", %{conn: conn} do
      StorageStub.put_replies(%{eject: {:error, :busy}})

      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :running))
      open_drawer(view)

      view |> element("button[phx-value-action='eject']") |> render_click()
      html = view |> element("button[phx-click='drive_eject']") |> render_click()

      assert_receive {:storage_call, :eject, [@drive_key]}
      assert html =~ "Drive is busy — stop Home Assistant backups first."
      refute html =~ "safe to unplug"
    end

    test "an unarmed password regeneration does nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :running))
      open_drawer(view)

      html = render_click(view, "drive_regenerate_password", %{})

      refute_receive {:storage_call, :rotate_password, _}
      assert html =~ "Confirm that action first."
    end

    test "arming, then confirming, still works after a refused confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      render_click(view, "drive_eject", %{})
      refute_receive {:storage_call, :eject, _}

      view |> element("button[phx-value-action='eject']") |> render_click()
      html = view |> element("button[phx-click='drive_eject']") |> render_click()

      assert_receive {:storage_call, :eject, [@drive_key]}
      assert html =~ "safe to unplug"
    end

    test "credentials that can't be read are reported, not implied to work", %{conn: conn} do
      # `share_credentials/0` answers nil both when the store is unreachable
      # and when a generated password could not be persisted.
      StorageStub.install(self(), credentials: nil)
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :running))

      html = open_drawer(view)

      assert html =~ "Share credentials are unavailable"
      refute html =~ "Username"
      refute html =~ "Regenerate password"
      # The share's path is still shown: it is not a credential.
      assert html =~ "Path"
    end

    test "eject needs a second confirmation, then says it's safe to unplug", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      open_drawer(view)

      html = view |> element("button[phx-value-action='eject']") |> render_click()
      assert html =~ "Eject USB drive (/dev/sda)?"
      refute_receive {:storage_call, :eject, _}

      html = view |> element("button[phx-click='drive_eject']") |> render_click()
      # The drive KEY goes over the façade, never a device path: the
      # subsystem accepts only the mounted drive's key.
      assert_receive {:storage_call, :eject, [@drive_key]}
      assert html =~ "safe to unplug"

      # The subsystem's follow-up state keeps the drive attached but unmounted.
      push_storage(storage_state(mount: nil, capacity: nil))
      html = render(view)
      assert html =~ "Re-plug the drive to mount it again."
      assert html =~ "Unmounted"

      # Re-plug: the drive mounts again and the ejected panel goes away
      # (the flash from the eject itself is still on screen, so assert on
      # the panel copy, not the toast).
      push_storage(storage_state())
      refute render(view) =~ "Re-plug the drive to mount it again."
    end

    test "unplugging the open drive closes its drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())
      assert open_drawer(view) =~ "Danger zone"

      push_storage(storage_state(drives: [], mount: nil, capacity: nil))
      refute render(view) =~ "Danger zone"
    end

    test "a second drive says only the first is used", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      second = drive(name: "sdb", dev_path: "/dev/sdb", slot_sub: "1-1.4", key: nil)
      push_storage(storage_state(drives: [drive(), second]))

      html = open_drawer(view, "/dev/sdb")
      assert html =~ "Only the first drive is used."
      # Its danger-zone actions are inert.
      assert html =~ "disabled"
    end

    test "the folder chooser lists the drive's directories and descends", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :running))
      open_drawer(view)

      html = view |> element("button[phx-click='drive_open_chooser']") |> render_click()
      assert_receive {:storage_call, :list_folders, ["/"]}
      assert html =~ "Choose backup folder"
      assert html =~ "backups"
      assert html =~ "media"

      html = view |> element("button[phx-value-path='backups']") |> render_click()
      assert_receive {:storage_call, :list_folders, ["backups"]}
      assert html =~ "No subfolders"
      assert html =~ "Share will map to"
    end

    test "picking a folder maps the share at that path", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :running))
      open_drawer(view)

      view |> element("button[phx-click='drive_open_chooser']") |> render_click()
      view |> element("button[phx-value-path='backups']") |> render_click()
      html = view |> element("button[phx-click='drive_chooser_pick']") |> render_click()

      assert_receive {:storage_call, :set_share_folder, [@drive_key, "backups"]}
      assert html =~ "Backups will be stored in backups."
    end

    test "creating a folder navigates into it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :running))
      open_drawer(view)

      view |> element("button[phx-click='drive_open_chooser']") |> render_click()
      view |> element("button[phx-click='drive_chooser_new']") |> render_click()

      view
      |> form("form[phx-submit='drive_chooser_create']", %{"name" => "backups"})
      |> render_submit()

      # A duplicate sibling is refused before the façade is called at all.
      assert_receive {:storage_call, :list_folders, ["/"]}
      refute_receive {:storage_call, :create_folder, _}

      html =
        view
        |> form("form[phx-submit='drive_chooser_create']", %{"name" => "ha"})
        |> render_submit()

      assert_receive {:storage_call, :create_folder, ["/", "ha"]}
      # Navigated into the new folder, so "Use this folder" picks it.
      assert html =~ "Share will map to"
      assert html =~ "ha"
    end

    test "a rejected folder name surfaces the façade's reason inline", %{conn: conn} do
      StorageStub.put_replies(%{create_folder: {:error, :eexist}})
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state(share: :running))
      open_drawer(view)

      view |> element("button[phx-click='drive_open_chooser']") |> render_click()
      view |> element("button[phx-click='drive_chooser_new']") |> render_click()

      html =
        view
        |> form("form[phx-submit='drive_chooser_create']", %{"name" => "ha"})
        |> render_submit()

      assert_receive {:storage_call, :create_folder, ["/", "ha"]}
      assert html =~ "A folder with that name already exists."
    end

    test "a firmware without smbd hides the share controls", %{conn: conn} do
      StorageStub.install(self(), supported?: false)
      {:ok, view, _html} = live(conn, "/")
      push_storage(storage_state())

      html = open_drawer(view)
      # HEEx escapes the apostrophe, so match the unambiguous tail.
      assert html =~ "available on this firmware."
      refute html =~ "Share as HA backup target"
      # The drive is still inspectable and formattable.
      assert html =~ "Danger zone"
    end
  end

  # `hardware_rows/2` is the slot-promotion + ordering core. It can't be
  # exercised through a live mount here: the host test env enumerates ports
  # dynamically (no declared `@external_slots`), so no empty slot ever
  # exists for a peripheral to be promoted into. Drive it directly instead.
  describe "hardware_rows/2 (slot promotion + ordering)" do
    defp slot(sub, n, opts \\ []) do
      %{slot: "USB #{n}", slot_sub: sub, connected: Keyword.get(opts, :connected, false)}
    end

    defp bt(sub) do
      %{type_label: "Bluetooth", slot: "Bluetooth", slot_sub: sub, name: "Dongle"}
    end

    defp audio do
      %{type_label: "Sound card", slot: "Sound card", slot_sub: nil, name: "Card"}
    end

    test "promotes a dongle into its matching empty slot, keeping declared order" do
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2), slot("1-1.2", 3), slot("1-1.3", 4)]

      assert [
               {:peripheral, %{slot: "USB 1", slot_sub: "1-1.1.2"}},
               {:port, %{slot_sub: "1-1.1.3"}},
               {:port, %{slot_sub: "1-1.2"}},
               {:port, %{slot_sub: "1-1.3"}}
             ] = OverviewLive.hardware_rows(ports, [bt("1-1.1.2")])
    end

    test "promotes into the correct slot regardless of which one the dongle fills" do
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2), slot("1-1.2", 3)]

      assert [
               {:port, %{slot_sub: "1-1.1.2"}},
               {:port, %{slot_sub: "1-1.1.3"}},
               {:peripheral, %{slot: "USB 3", slot_sub: "1-1.2"}}
             ] = OverviewLive.hardware_rows(ports, [bt("1-1.2")])
    end

    test "never replaces a connected port; an unclaimed dongle trails" do
      ports = [slot("1-1.1.2", 1, connected: true)]

      assert [
               {:port, %{slot_sub: "1-1.1.2", connected: true}},
               {:peripheral, %{slot: "Bluetooth", slot_sub: "1-1.1.2"}}
             ] = OverviewLive.hardware_rows(ports, [bt("1-1.1.2")])
    end

    test "audio cards (no slot path) and unmatched dongles trail in order" do
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2)]
      peripherals = [audio(), bt("1-1.1.2"), bt("9-9.9")]

      assert [
               {:peripheral, %{slot: "USB 1", slot_sub: "1-1.1.2"}},
               {:port, %{slot_sub: "1-1.1.3"}},
               {:peripheral, %{type_label: "Sound card"}},
               {:peripheral, %{slot: "Bluetooth", slot_sub: "9-9.9"}}
             ] = OverviewLive.hardware_rows(ports, peripherals)
    end

    test "promotes a USB sound card into its slot; an SoC card still trails" do
      ports = [slot("1-1.1.2", 1), slot("1-1.3", 2)]
      usb_card = %{type_label: "Sound card", slot: "Sound card", slot_sub: "1-1.3", name: "DAC"}

      assert [
               {:port, %{slot_sub: "1-1.1.2"}},
               {:peripheral, %{slot: "USB 2", slot_sub: "1-1.3", name: "DAC"}},
               {:peripheral, %{type_label: "Sound card", slot_sub: nil}}
             ] = OverviewLive.hardware_rows(ports, [audio(), usb_card])
    end
  end

  describe "hardware_rows/3 (USB hub tree)" do
    defp card(sub, name) do
      %{type_label: "Sound card", slot: "Sound card", slot_sub: sub, name: name}
    end

    @hub %{vendor_id: 0x0A12, product_id: 0x4010, name: "USB hub"}

    test "renders a hub at its slot with devices behind it indented (depth 1)" do
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2), slot("1-1.2", 3), slot("1-1.3", 4)]
      peripherals = [card("1-1.1.3.1", "FlooGoo FMA120")]
      hubs = %{"1-1.1.3" => @hub}

      assert [
               {:port, %{slot_sub: "1-1.1.2"}},
               {:hub,
                %{slot: "USB 2", slot_sub: "1-1.1.3", name: "USB hub", vidpid: "0A12:4010"}},
               {:peripheral, %{slot_sub: "1-1.1.3.1", depth: 1}},
               {:port, %{slot_sub: "1-1.2"}},
               {:port, %{slot_sub: "1-1.3"}}
             ] = OverviewLive.hardware_rows(ports, peripherals, hubs)
    end

    test "collapses a child that has both a serial port and a peripheral into the peripheral" do
      # The FMA120's ttyACM (a bonus port) and its sound card share 1-1.1.3.1.
      child_port = slot("1-1.1.3.1", 5, connected: true)
      ports = [slot("1-1.1.3", 2), child_port]
      peripherals = [card("1-1.1.3.1", "FlooGoo FMA120")]
      hubs = %{"1-1.1.3" => @hub}

      rows = OverviewLive.hardware_rows(ports, peripherals, hubs)

      # One hub + exactly one child row (the peripheral), no stray child port.
      assert [
               {:hub, %{slot_sub: "1-1.1.3"}},
               {:peripheral, %{slot_sub: "1-1.1.3.1", depth: 1}}
             ] = rows

      refute Enum.any?(rows, &match?({:port, %{slot_sub: "1-1.1.3.1"}}, &1))
    end

    test "orders children by bus path, interleaving ports and peripherals" do
      # Hub with a serial port at .1 and a sound card at .2 — must render in
      # bus-path order (.1 then .2), not peripherals-then-ports.
      child_port = slot("1-1.1.3.1", 5, connected: true)
      ports = [slot("1-1.1.3", 2), child_port]
      peripherals = [card("1-1.1.3.2", "Card")]
      hubs = %{"1-1.1.3" => @hub}

      assert [
               {:hub, %{slot_sub: "1-1.1.3"}},
               {:port, %{slot_sub: "1-1.1.3.1", depth: 1}},
               {:peripheral, %{slot_sub: "1-1.1.3.2", depth: 1}}
             ] = OverviewLive.hardware_rows(ports, peripherals, hubs)
    end

    test "a child port with no peripheral renders as an indented port row" do
      child_port = slot("1-1.1.3.1", 5, connected: true)
      ports = [slot("1-1.1.3", 2), child_port]
      hubs = %{"1-1.1.3" => @hub}

      assert [
               {:hub, %{slot_sub: "1-1.1.3"}},
               {:port, %{slot_sub: "1-1.1.3.1", depth: 1}}
             ] = OverviewLive.hardware_rows(ports, [], hubs)
    end

    test "ignores hubs that aren't a rendered slot (board-internal ancestor hubs)" do
      # The board's internal hubs (1-1, 1-1.1) are ancestors of the declared
      # slots and class-09, so usb_hubs/0 reports them — but they must NOT be
      # treated as tree-roots or they'd swallow every slot as a child.
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2), slot("1-1.2", 3), slot("1-1.3", 4)]

      hubs = %{
        "1-1" => @hub,
        "1-1.1" => @hub,
        "1-1.1.3" => @hub
      }

      assert [
               {:port, %{slot_sub: "1-1.1.2"}},
               {:hub, %{slot_sub: "1-1.1.3"}},
               {:port, %{slot_sub: "1-1.2"}},
               {:port, %{slot_sub: "1-1.3"}}
             ] = OverviewLive.hardware_rows(ports, [], hubs)
    end

    test "with no hubs the output is identical to hardware_rows/2" do
      ports = [slot("1-1.1.2", 1), slot("1-1.1.3", 2)]
      peripherals = [card("1-1.1.2", "DAC")]

      assert OverviewLive.hardware_rows(ports, peripherals, %{}) ==
               OverviewLive.hardware_rows(ports, peripherals)
    end
  end

  describe "slot_summary/5 (physical-slot occupancy across device types)" do
    @slots ["1-1.1.2", "1-1.1.3", "1-1.2", "1-1.3"]

    # All four receptacles full, by different device types: USB1 BT dongle,
    # USB2 FMA120 (audio+serial behind its hub), USB3 streaming audio, USB4 idle
    # audio. The serial-only count used to read "1/5"; this must read 4/4.
    defp full_board do
      ports = [
        %{connected: false, slot_sub: "1-1.1.2", in_use: false},
        %{connected: false, slot_sub: "1-1.1.3", in_use: false},
        %{connected: false, slot_sub: "1-1.2", in_use: false},
        %{connected: false, slot_sub: "1-1.3", in_use: false},
        %{connected: true, slot_sub: "1-1.1.3.1", in_use: false}
      ]

      audio = %{
        a: %{key: {"1-1.1.3.1", 0x0A12, 0x4007}, usb_port: "1-1.1.3.1", stream: nil},
        b: %{key: {"1-1.2", 1, 1}, usb_port: "1-1.2", stream: %{codec: "flac"}},
        c: %{key: {"1-1.3", 2, 2}, usb_port: "1-1.3", stream: nil}
      }

      bt = [%{bus: :usb, port: "1-1.1.2", hci: "hci1", in_use?: true}]
      hubs = %{"1-1" => %{}, "1-1.1" => %{}, "1-1.1.3" => %{}}
      {ports, audio, bt, hubs}
    end

    test "counts every occupied receptacle, not just serial ports" do
      {ports, audio, bt, hubs} = full_board()
      s = OverviewLive.slot_summary(ports, audio, bt, hubs, @slots)
      assert s.total == 4
      assert s.in_use == 4
      # Active: USB1 (BT in use) + USB3 (audio streaming).
      assert s.active == 2
      assert s.idle == 2
    end

    test "an empty board reads 0 in use" do
      s = OverviewLive.slot_summary([], %{}, [], %{}, @slots)
      assert s == %{in_use: 0, total: 4, active: 0, idle: 0}
    end

    test "two devices on the same child bus path count their slot once" do
      # The FMA120's serial port and its sound card share 1-1.1.3.1 (under USB 2).
      ports = [%{connected: true, slot_sub: "1-1.1.3.1", in_use: false}]
      audio = %{a: %{key: {"1-1.1.3.1", 0x0A12, 0x4007}, usb_port: "1-1.1.3.1", stream: nil}}
      s = OverviewLive.slot_summary(ports, audio, [], %{}, @slots)
      assert s == %{in_use: 1, total: 4, active: 0, idle: 1}
    end

    test "a capture-only input occupies its slot; active only while streaming" do
      # Input rows carry `:status` (never `:stream`); a streaming source counts
      # as active, an idle/detected one as merely occupied.
      idle = %{a: %{key: {"1-1.2", 1, 1}, usb_port: "1-1.2", status: :detected}}
      s1 = OverviewLive.slot_summary([], idle, [], %{}, @slots)
      assert s1 == %{in_use: 1, total: 4, active: 0, idle: 1}

      live = %{a: %{key: {"1-1.2", 1, 1}, usb_port: "1-1.2", status: :streaming}}
      s2 = OverviewLive.slot_summary([], live, [], %{}, @slots)
      assert s2 == %{in_use: 1, total: 4, active: 1, idle: 0}
    end

    test "a duplex device capturing (no output stream) counts as active" do
      # A duplex device merges as an output row (usb key, no `:stream`) carrying
      # the input's live capture signal `:capturing?`. It must count as active
      # even though the output side isn't streaming, so a capture-in-use device
      # doesn't read as idle.
      idle = %{a: %{key: {"1-1.2", 1, 1}, usb_port: "1-1.2", stream: nil, capturing?: false}}
      assert OverviewLive.slot_summary([], idle, [], %{}, @slots).active == 0

      capturing = %{a: %{key: {"1-1.2", 1, 1}, usb_port: "1-1.2", stream: nil, capturing?: true}}
      s = OverviewLive.slot_summary([], capturing, [], %{}, @slots)
      assert s == %{in_use: 1, total: 4, active: 1, idle: 0}
    end

    test "a BT radio without a :port (hci-only) is not counted" do
      bt = [%{bus: :usb, hci: "hci0", in_use?: true}]
      assert OverviewLive.slot_summary([], %{}, bt, %{}, @slots).in_use == 0
    end

    test "dynamic target (no slot map) reports devices as N/N" do
      {ports, audio, bt, hubs} = full_board()
      s = OverviewLive.slot_summary(ports, audio, bt, hubs, nil)
      # Distinct device paths: 1-1.1.3.1 (serial+audio), 1-1.2, 1-1.3, 1-1.1.2.
      assert s == %{in_use: 4, total: 4, active: 2, idle: 2}
    end
  end
end
