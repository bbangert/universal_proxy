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

  alias BlueHeron.HCI.Command.{ControllerAndBaseband, VendorSpecific}
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

  Mirrors the Linux kernel `btbcm` finalize path. After the firmware
  records (ending in `LaunchRAM`), before resuming the standard HCI
  setup queue:

  1. `{:delay, 250}` — the chip reboots its CPU into the patched
     firmware on `LaunchRAM`. Linux's `btbcm_patchram` sleeps 250ms
     here ("250 msec delay after Launch Ram completes"). Do NOT touch
     the UART during this window.
  2. `:uart_flush_rx` — flush the host UART's receive buffer (and the
     framer's mid-frame state) to clear any garbage bytes the chip
     emits during the ROM→patch handoff.
  3. `%ControllerAndBaseband.Reset{}` — Linux's `btbcm_finalize`
     re-enters `btbcm_initialize`, whose first command against the
     patched firmware is HCI Reset. This is the chip's expected
     post-launch re-sync point.
  4. `{:delay, 100}` — Linux's `btbcm_reset` sleeps 100ms after Reset
     ("100 msec delay for module to complete reset process") before
     the next command (Read_Local_Version / Read_BD_ADDR, which the
     standard setup queue then issues).

  History: earlier iterations chased a UART-layer "chip is silent
  after LaunchRAM" symptom with termios re-apply, a 20ms BREAK pulse,
  and using Read_BD_ADDR instead of Reset as the sync point. None of
  it helped, because the real cause was loading the wrong-variant
  firmware (`BCM4345C5.hcd` for an LMP `0x6119` chip that is actually
  a `BCM4345C0` — see `FirmwareLoader`). With the correct `.hcd`, the
  plain Linux-equivalent Reset sequence is what the chip expects. The
  `:uart_configure_resync` and `:uart_break_wake` helpers remain in
  `BlueHeron.HCI.Transport` as opt-in steps but are no longer part of
  the default sequence.

  Implementation note: we deliberately do NOT drain TX here.
  `Circuits.UART.drain/1` (`tcdrain(3)`) blocks until the TX buffer
  is empty, and on a freshly-restarted BCM chip CTS may be
  temporarily de-asserted, causing drain to block. RX-only flush is
  the safe equivalent.
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
              [{:delay, 250}, :uart_flush_rx] ++
              [%ControllerAndBaseband.Reset{}, {:delay, 100}]

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
