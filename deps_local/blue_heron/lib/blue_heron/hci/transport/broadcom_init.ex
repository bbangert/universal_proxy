# SPDX-FileCopyrightText: 2024 Connor Rigby
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule BlueHeron.HCI.Transport.BroadcomInit do
  @moduledoc """
  Generates the vendor-specific initialization command sequence for
  Broadcom/Cypress/Infineon Bluetooth controllers.

  This module handles firmware downloading from `.hcd` files using
  the Broadcom vendor-specific HCI protocol.
  """

  require Logger

  alias BlueHeron.HCI.Command.{InformationalParameters, VendorSpecific}
  alias BlueHeron.HCI.Transport.UART.FirmwareLoader

  @broadcom_manufacturer_id 15

  @default_firmware_path Application.app_dir(:blue_heron, "priv/firmware/brcm")

  @doc """
  Returns `true` if the manufacturer ID indicates a Broadcom controller.
  """
  @spec broadcom?(non_neg_integer()) :: boolean()
  def broadcom?(manufacturer_name), do: manufacturer_name == @broadcom_manufacturer_id

  @doc """
  Generate vendor initialization commands for a Broadcom controller.

  Looks up the firmware file based on the chip's LMP subversion, parses it,
  and returns a list of setup commands to be prepended to the standard
  HCI initialization sequence.

  Returns an empty list if no firmware is needed or the firmware file is not found.

  ## Post-LaunchRAM sequence

  After firmware load, before resuming the standard HCI setup queue:

  1. `{:delay, 3000}` — give the chip time to relaunch from patch RAM.
  2. `:uart_flush_rx` — flush the host UART's receive buffer (and the
     framer's mid-frame state) to clear any garbage bytes the chip
     emits during the ROM→patch handoff.
  3. `{:delay, 200}` — let the chip settle after the flush.
  4. `:uart_configure_resync` — re-apply host UART termios. Mirrors
     what Linux's `bcm_setup` gets implicitly when it calls
     `host_set_baudrate(hu, init_speed)` → `tty_set_termios`.
  5. `{:delay, 50}` — spacer.
  6. `:uart_break_wake` — pulse a 20ms UART BREAK to wake the chip
     from any post-firmware sleep state. Some Cypress/Broadcom
     patches enable sleep mode by default after `LaunchRAM`; in
     that state the chip ignores all HCI commands (including
     `Set_Sleep_Mode` itself) until it observes a BREAK or a
     BT_DEV_WAKE GPIO transition.
  7. `{:delay, 50}` — spacer.
  8. `%InformationalParameters.ReadBdAddr{}` — used here as the
     post-firmware **sync point**, mirroring Linux's
     `btbcm_initialize` which reads BD_ADDR (NOT Reset) as the
     first post-firmware HCI command. The Linux kernel driver
     elides Reset entirely after firmware-load; the pre-firmware
     Reset + Read_Local_Version already initialized state, and a
     post-firmware Reset would undo the patch.

  Implementation note: we deliberately do NOT drain TX here.
  `Circuits.UART.drain/1` (`tcdrain(3)`) blocks until the TX buffer
  is empty, and on a freshly-restarted BCM chip CTS may be
  temporarily de-asserted, causing drain to block. RX-only flush
  + termios re-apply + BREAK pulse are the safe equivalents.

  Reset (`0x0C03`) and UpdateBaudrate (`0xFC18`) were both tried
  as the post-firmware sync point on BCM4345C5 (Pi 3 B+); both
  hang forever with the chip emitting zero UART bytes. Read_BD_ADDR
  is what Linux btbcm uses, so it's the next test point.
  """
  @spec vendor_init_commands(map(), String.t() | nil) :: list()
  def vendor_init_commands(setup_params, firmware_path \\ nil) do
    firmware_path = firmware_path || @default_firmware_path
    lmp_subversion = Map.get(setup_params, :lmp_pal_subversion, 0)

    case FirmwareLoader.firmware_name(lmp_subversion) do
      nil ->
        Logger.info(
          "No firmware mapping for LMP subversion #{inspect(lmp_subversion, base: :hex)}"
        )

        []

      name ->
        hcd_path = Path.join(firmware_path, name)

        case File.read(hcd_path) do
          {:ok, hcd_data} ->
            hcd_commands = FirmwareLoader.parse_hcd(hcd_data)
            Logger.info("Loading Broadcom firmware: #{name} (#{length(hcd_commands)} records)")

            [%VendorSpecific.DownloadMinidriver{}, {:delay, 50}] ++
              Enum.map(hcd_commands, &{:raw_hci, &1}) ++
              [{:delay, 3000}, :uart_flush_rx, {:delay, 200}] ++
              [:uart_configure_resync, {:delay, 50}] ++
              [:uart_break_wake, {:delay, 50}] ++
              [%InformationalParameters.ReadBdAddr{}]

          {:error, :enoent} ->
            Logger.warning("Broadcom firmware file not found: #{hcd_path}")
            []

          {:error, reason} ->
            Logger.error("Failed to read firmware file #{hcd_path}: #{inspect(reason)}")
            []
        end
    end
  end
end
