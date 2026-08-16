defmodule UniversalProxy.Audio.Input.Enumerate do
  @moduledoc """
  Enumerate ALSA capture-capable cards from sysfs/procfs on Linux.

  Parallel to `UniversalProxy.Audio.Enumerate` (playback outputs), but only
  includes cards that expose at least one CAPTURE substream — presence of a
  `/sys/class/sound/pcmC<idx>D<n>c` node (trailing `c`; playback nodes end
  in `p`). A card with only playback substreams is excluded entirely; a
  duplex card (both directions) is included and keys off its capture side.

  Inputs are keyed by the same `{slot_sub, vendor_id, product_id}` shape as
  `Audio.Enumerate`'s outputs — `{usb_port || card_name, vid, pid}` — so
  the identity survives hotplug re-enumeration even though ALSA card
  *indexes* are not stable across it. `alsa_device` is always resolved from
  the CURRENT card index (and the lowest capture device number under that
  card) at read time; only the key tuple is treated as a stable identity.

  ## Filesystem roots

  Reads `/proc/asound/cards` and `/sys/class/sound/`, same as
  `Audio.Enumerate`, and honors the same application-env overrides
  (`:audio_proc_root`, `:audio_sys_root`) so host tests can point both
  enumerators at one synthesised tree.

  ## Failure tolerance

  `safe/0` rescues any unexpected failure (malformed input, missing paths,
  permission errors) and returns `%{}`, matching `Audio.Enumerate`'s
  contract.
  """

  require Logger

  alias UniversalProxy.Audio.Enumerate

  @type slot_sub :: String.t()
  @type vendor_id :: non_neg_integer() | nil
  @type product_id :: non_neg_integer() | nil
  @type input_key :: {slot_sub(), vendor_id(), product_id()}

  @type input_info :: %{
          name: String.t(),
          alsa_device: String.t(),
          card_index: non_neg_integer(),
          vid: vendor_id(),
          pid: product_id(),
          usb_port: String.t() | nil
        }

  @doc """
  List ALSA capture inputs as a `%{key => info}` map, swallowing any
  filesystem or parse error and returning `%{}` on failure.
  """
  @spec safe() :: %{input_key() => input_info()}
  def safe do
    list_inputs()
  rescue
    e ->
      Logger.warning(
        "Audio input enumerate failed: #{Exception.format(:error, e, __STACKTRACE__)}"
      )

      %{}
  end

  @doc """
  Same as `safe/0` but allows callers (mostly tests) to point at
  alternative filesystem roots.
  """
  @spec list_inputs(keyword()) :: %{input_key() => input_info()}
  def list_inputs(opts \\ []) do
    proc_root = Keyword.get(opts, :proc_root, proc_root())
    sys_root = Keyword.get(opts, :sys_root, sys_root())
    cards_path = Path.join([proc_root, "asound", "cards"])

    case File.read(cards_path) do
      {:ok, content} ->
        content
        |> Enumerate.parse_cards()
        |> Enum.reduce(%{}, &put_capture_card(&1, &2, sys_root))

      {:error, :enoent} ->
        %{}

      {:error, reason} ->
        Logger.warning("Audio input enumerate could not read #{cards_path}: #{inspect(reason)}")
        %{}
    end
  end

  defp put_capture_card({index, card_name}, acc, sys_root) do
    case lowest_capture_device(sys_root, index) do
      nil ->
        acc

      dev ->
        {vid, pid} = read_vid_pid(sys_root, index)
        usb_port = read_usb_port(sys_root, index)

        # USB cards key by their physical bus path so two identical adapters
        # (same name + VID/PID) are distinct inputs rather than colliding on
        # one key; SoC cards have no port and key by the card name.
        key = {usb_port || card_name, vid, pid}

        info = %{
          name: card_name,
          alsa_device: "plughw:#{index},#{dev}",
          card_index: index,
          vid: vid,
          pid: pid,
          usb_port: usb_port
        }

        Map.put(acc, key, info)
    end
  end

  # -- Capture-substream detection --

  # `pcmC<card>D<dev>c` / `...p` nodes live directly under `sys_root`
  # (siblings of `cardN`, not nested inside it) — trailing `c` = capture,
  # `p` = playback. A duplex card exposes both for the same device number;
  # we pick the LOWEST capture device number so `plughw:<idx>,<dev>` names
  # the capture-capable subdevice even when playback devices are numbered
  # lower on the same card.
  @capture_node_re ~r/^pcmC(\d+)D(\d+)c$/

  defp lowest_capture_device(sys_root, card_index) do
    case File.ls(sys_root) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(&capture_device_number(&1, card_index))
        |> case do
          [] -> nil
          devs -> Enum.min(devs)
        end

      _ ->
        nil
    end
  end

  defp capture_device_number(name, card_index) do
    case Regex.run(@capture_node_re, name) do
      [_, card_str, dev_str] ->
        with {^card_index, ""} <- Integer.parse(card_str),
             {dev, ""} <- Integer.parse(dev_str) do
          [dev]
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  # -- VID/PID lookup --

  # Duplicated from `Audio.Enumerate` rather than extracted: it's a private
  # helper there and the output enumerator's surface is not to be touched.
  # See `Audio.Enumerate`'s moduledoc for the `PRODUCT=` uevent field shape.
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

  # Same interface-segment-only matching as `Audio.Enumerate` — never a bare
  # parent segment like "1-1", so we can't mistake the hub for the device.
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
