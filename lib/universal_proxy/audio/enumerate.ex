defmodule UniversalProxy.Audio.Enumerate do
  @moduledoc """
  Enumerate ALSA playback outputs from sysfs/procfs on Linux.

  The audio subsystem treats every reachable ALSA playback card as an
  independently discoverable Sendspin output. This module is the single
  source of truth for "which cards exist right now" — `Audio.Server`
  polls it every 5 s and diffs against its in-memory cache.

  Outputs are keyed by a `{slot_sub, vendor_id, product_id}` tuple,
  identical in spirit to `UniversalProxy.UART.Store`'s key shape. For
  built-in SoC cards (Pi 3 / Pi 4 `bcm2835_*`) the VID/PID slots are
  `nil` and `slot_sub` is the long card name. A USB DAC keys by its
  physical bus path — `{usb_port, vendor_id, product_id}` — so two
  identical adapters (same name + VID/PID) in different ports are distinct
  outputs instead of colliding on one key. Each output also carries
  `:usb_port` (the bus path, e.g. `"1-1.3"`; `nil` for SoC cards) so the
  Overview can render it in its declared slot, and `:card_name` (the raw
  ALSA name) for display.

  ## Filesystem roots

  Reads `/proc/asound/cards` and `/sys/class/sound/`. Both roots are
  overridable via application env (`:audio_proc_root`, `:audio_sys_root`)
  to make host-side tests deterministic.

  ## Failure tolerance

  `safe/0` rescues any unexpected failure (malformed input, missing
  paths, permission errors) and returns `%{}`. The supervisor must
  come up cleanly on CI hosts and on Pis with `dtparam=audio=off`,
  which is why no path is allowed to raise.
  """

  require Logger

  @type slot_sub :: String.t()
  @type vendor_id :: non_neg_integer() | nil
  @type product_id :: non_neg_integer() | nil
  @type output_key :: {slot_sub(), vendor_id(), product_id()}

  @type output_info :: %{
          card_index: non_neg_integer(),
          alsa_device: String.t(),
          card_name: String.t(),
          usb_port: String.t() | nil
        }

  @doc """
  List ALSA playback outputs as a `%{key => info}` map, swallowing any
  filesystem or parse error and returning `%{}` on failure.
  """
  @spec safe() :: %{output_key() => output_info()}
  def safe do
    list_outputs()
  rescue
    e ->
      Logger.warning("Audio enumerate failed: #{Exception.format(:error, e, __STACKTRACE__)}")

      %{}
  end

  @doc """
  Same as `safe/0` but allows callers (mostly tests) to point at
  alternative filesystem roots.
  """
  @spec list_outputs(keyword()) :: %{output_key() => output_info()}
  def list_outputs(opts \\ []) do
    proc_root = Keyword.get(opts, :proc_root, proc_root())
    sys_root = Keyword.get(opts, :sys_root, sys_root())
    cards_path = Path.join([proc_root, "asound", "cards"])

    case File.read(cards_path) do
      {:ok, content} ->
        content
        |> parse_cards()
        |> Enum.into(%{}, fn {index, card_name} ->
          {vid, pid} = read_vid_pid(sys_root, index)
          usb_port = read_usb_port(sys_root, index)

          # USB cards key by their physical bus path so two identical adapters
          # (same name + VID/PID) are distinct outputs rather than colliding on
          # one key; SoC cards have no port and key by the card name.
          key = {usb_port || card_name, vid, pid}

          info = %{
            card_index: index,
            alsa_device: "plughw:#{index},0",
            card_name: card_name,
            usb_port: usb_port
          }

          {key, info}
        end)

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("Audio enumerate could not read #{cards_path}: #{inspect(reason)}")
        %{}
    end
  end

  # -- Parsing --

  # `/proc/asound/cards` example (Pi 3 with 3.5 mm jack):
  #
  #      0 [Headphones     ]: bcm2835_headphonE - bcm2835 Headphones
  #                           bcm2835 Headphones
  #
  # The header line carries everything we need: card index, short id,
  # driver, and long name. The second line is the long name indented
  # and is intentionally ignored.
  @card_header_re ~r/^\s*(\d+)\s*\[\s*\S[^\]]*?\s*\]\s*:\s+\S+\s+-\s+(.+?)\s*$/

  @doc false
  @spec parse_cards(binary()) :: [{non_neg_integer(), String.t()}]
  def parse_cards(content) when is_binary(content) do
    content
    |> String.split("\n", trim: false)
    |> Enum.flat_map(&parse_card_header/1)
  end

  defp parse_card_header(line) do
    case Regex.run(@card_header_re, line) do
      [_, index_str, long_name] ->
        case Integer.parse(index_str) do
          {index, ""} -> [{index, String.trim(long_name)}]
          _ -> []
        end

      _ ->
        []
    end
  end

  # -- VID/PID lookup --

  # USB-attached sound cards expose
  # `/sys/class/sound/cardN/device/uevent` containing a `PRODUCT=`
  # line of the form `PRODUCT=vid/pid/bcd` (hex, no `0x` prefix). SoC
  # built-in cards (Pi's `bcm2835`) have no such field; we return
  # `{nil, nil}` for those so the key tuple is unambiguous.
  defp read_vid_pid(sys_root, index) do
    path = Path.join([sys_root, "card#{index}", "device", "uevent"])

    case File.read(path) do
      {:ok, content} -> parse_uevent_product(content)
      _ -> {nil, nil}
    end
  end

  @product_re ~r/^PRODUCT=([0-9a-fA-F]+)\/([0-9a-fA-F]+)/m

  defp parse_uevent_product(content) do
    case Regex.run(@product_re, content) do
      [_, vid_hex, pid_hex] ->
        with {vid, ""} <- Integer.parse(vid_hex, 16),
             {pid, ""} <- Integer.parse(pid_hex, 16) do
          {vid, pid}
        else
          _ -> {nil, nil}
        end

      _ ->
        {nil, nil}
    end
  end

  # -- USB bus path lookup --

  # The physical USB-A receptacle a USB sound card occupies, e.g. "1-1.3",
  # so the Overview can place it in its declared slot instead of a separate
  # row (mirrors `UniversalProxy.Bluetooth.Radios` for BT dongles). The card's
  # `device` symlink resolves to the bound USB interface
  # (".../1-1/1-1.3/1-1.3:1.0"); the bus path is the interface segment
  # (".../1-1.3:1.0") with the ":interface" suffix stripped. We match only the
  # interface form — never a bare parent segment like "1-1" — so we can't
  # mistake the hub for the device. `nil` when no interface segment is present
  # (SoC cards point at a platform device; tests where `device` is a plain dir
  # have no symlink), which leaves the card to trail rather than mis-slot it.
  @usb_iface_re ~r/^(\d+-[\d.]+):\d+\.\d+$/

  defp read_usb_port(sys_root, index) do
    link = Path.join([sys_root, "card#{index}", "device"])

    case File.read_link(link) do
      {:ok, target} -> usb_bus_path(target)
      _ -> nil
    end
  end

  defp usb_bus_path(symlink_target) do
    symlink_target
    |> String.split("/")
    |> Enum.find_value(fn seg ->
      case Regex.run(@usb_iface_re, seg) do
        [_, bus] -> bus
        _ -> nil
      end
    end)
  end

  # -- Filesystem root configuration --

  defp proc_root, do: Application.get_env(:universal_proxy, :audio_proc_root, "/proc")
  defp sys_root, do: Application.get_env(:universal_proxy, :audio_sys_root, "/sys/class/sound")
end
