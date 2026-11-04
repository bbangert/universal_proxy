defmodule Circuits.CEC.Struct do
  @moduledoc """
  Encoders and decoders for the kernel CEC structs in `<linux/cec.h>`.

  The `cec_port` helper moves these structs between the kernel and Elixir as
  raw bytes; all layout knowledge lives here. Layouts are little-endian and
  identical on every supported target (armv6, armv7, aarch64, x86_64), and
  the helper's compile-time asserts fail the build if that ever changes.

  | struct | bytes | ioctls |
  |---|---|---|
  | `cec_msg` | 56 | `CEC_TRANSMIT`, `CEC_RECEIVE` |
  | `cec_log_addrs` | 92 | `CEC_ADAP_G_LOG_ADDRS`, `CEC_ADAP_S_LOG_ADDRS` |
  | `cec_event` | 80 | `CEC_DQEVENT` |
  | `cec_caps` | 76 | `CEC_ADAP_G_CAPS` |
  | `cec_connector_info` | 68 | `CEC_ADAP_G_CONNECTOR_INFO` |

  Decoders are total on binaries of the right size and keep integer fields
  as integers, so decoding then encoding a kernel-produced struct gives the
  same bytes. `flags/2`, `tx_outcome/1`, `rx_outcome/1` and `classify/1`
  interpret them.
  """

  import Bitwise

  @msg_size 56
  @log_addrs_size 92
  @event_size 80
  @caps_size 76
  @connector_info_size 68

  @osd_name_size 15
  @invalid_log_addr 0xFF

  @type msg :: %{
          tx_ts: non_neg_integer(),
          rx_ts: non_neg_integer(),
          timeout: non_neg_integer(),
          sequence: non_neg_integer(),
          flags: non_neg_integer(),
          msg: binary(),
          reply: byte(),
          rx_status: byte(),
          tx_status: byte(),
          tx_arb_lost_cnt: byte(),
          tx_nack_cnt: byte(),
          tx_low_drive_cnt: byte(),
          tx_error_cnt: byte()
        }

  @type log_addrs :: %{
          log_addr: [byte()],
          log_addr_mask: non_neg_integer(),
          cec_version: byte(),
          num_log_addrs: byte(),
          vendor_id: non_neg_integer(),
          flags: non_neg_integer(),
          osd_name: binary(),
          primary_device_type: [byte()],
          log_addr_type: [byte()],
          all_device_types: [byte()],
          features: [binary()]
        }

  @type event_type ::
          :state_change
          | :lost_msgs
          | :pin_cec_low
          | :pin_cec_high
          | :pin_hpd_low
          | :pin_hpd_high
          | :pin_5v_low
          | :pin_5v_high
          | non_neg_integer()

  @type event :: %{
          required(:ts) => non_neg_integer(),
          required(:event) => event_type(),
          required(:flags) => non_neg_integer(),
          required(:raw) => binary(),
          optional(:phys_addr) => non_neg_integer(),
          optional(:log_addr_mask) => non_neg_integer(),
          optional(:have_conn_info) => non_neg_integer(),
          optional(:lost_msgs) => non_neg_integer()
        }

  @type caps :: %{
          driver: binary(),
          name: binary(),
          available_log_addrs: non_neg_integer(),
          capabilities: non_neg_integer(),
          version: non_neg_integer()
        }

  @type connector_info :: %{
          required(:type) => :none | :drm | non_neg_integer(),
          required(:raw) => binary(),
          optional(:card_no) => non_neg_integer(),
          optional(:connector_id) => non_neg_integer()
        }

  @type flag_kind :: :tx_status | :rx_status | :msg | :log_addrs | :caps | :event

  @type initiator_mode :: :none | :initiator | :exclusive
  @type follower_mode ::
          :none
          | :follower
          | :exclusive
          | :exclusive_passthru
          | :monitor_pin
          | :monitor
          | :monitor_all

  @flag_tables %{
    tx_status: [
      ok: 0x01,
      arb_lost: 0x02,
      nack: 0x04,
      low_drive: 0x08,
      error: 0x10,
      max_retries: 0x20,
      aborted: 0x40,
      timeout: 0x80
    ],
    rx_status: [ok: 0x01, timeout: 0x02, feature_abort: 0x04, aborted: 0x08],
    msg: [reply_to_followers: 0x01, raw: 0x02, reply_vendor_id: 0x04],
    log_addrs: [allow_unreg_fallback: 0x01, allow_rc_passthru: 0x02, cdc_only: 0x04],
    caps: [
      phys_addr: 0x001,
      log_addrs: 0x002,
      transmit: 0x004,
      passthrough: 0x008,
      rc: 0x010,
      monitor_all: 0x020,
      needs_hpd: 0x040,
      monitor_pin: 0x080,
      connector_info: 0x100,
      reply_vendor_id: 0x200
    ],
    event: [initial_state: 0x01, dropped_events: 0x02]
  }

  @event_types [
    state_change: 1,
    lost_msgs: 2,
    pin_cec_low: 3,
    pin_cec_high: 4,
    pin_hpd_low: 5,
    pin_hpd_high: 6,
    pin_5v_low: 7,
    pin_5v_high: 8
  ]

  @initiator_modes [none: 0x00, initiator: 0x01, exclusive: 0x02]
  @follower_modes [
    none: 0x00,
    follower: 0x10,
    exclusive: 0x20,
    exclusive_passthru: 0x30,
    monitor_pin: 0xD0,
    monitor: 0xE0,
    monitor_all: 0xF0
  ]

  @log_addr_types [
    tv: 0,
    record: 1,
    tuner: 2,
    playback: 3,
    audio_system: 4,
    specific: 5,
    unregistered: 6
  ]

  @all_device_types [
    tv: 0x80,
    record: 0x40,
    tuner: 0x20,
    playback: 0x10,
    audio_system: 0x08,
    switch: 0x04
  ]

  ## cec_msg

  @doc "Size of `struct cec_msg` in bytes."
  @spec msg_size() :: 56
  def msg_size, do: @msg_size

  @doc """
  Builds a `struct cec_msg`.

  `:msg` (1–16 bytes: header, opcode, operands) is required. `:timeout`
  (ms to wait for a reply), `:reply` (opcode to wait for, 0 for none) and
  `:flags` default to 0, as do the fields the kernel fills in (accepted so
  tests can build received structs).
  """
  @spec encode_msg(map() | keyword()) :: <<_::448>>
  def encode_msg(fields) when is_list(fields), do: encode_msg(Map.new(fields))

  def encode_msg(%{msg: msg} = f) when is_binary(msg) and byte_size(msg) in 1..16 do
    len = byte_size(msg)

    <<get(f, :tx_ts)::little-64, get(f, :rx_ts)::little-64, len::little-32,
      get(f, :timeout)::little-32, get(f, :sequence)::little-32, get(f, :flags)::little-32,
      msg::binary, 0::size((16 - len) * 8), get(f, :reply)::8, get(f, :rx_status)::8,
      get(f, :tx_status)::8, get(f, :tx_arb_lost_cnt)::8, get(f, :tx_nack_cnt)::8,
      get(f, :tx_low_drive_cnt)::8, get(f, :tx_error_cnt)::8, 0::8>>
  end

  @doc """
  Decodes a `struct cec_msg`.

  Total on any 56-byte binary: a `len` above 16 is clamped to 16, so `:msg`
  is always the valid prefix of the message buffer.
  """
  @spec decode_msg(<<_::448>>) :: msg()
  def decode_msg(
        <<tx_ts::little-64, rx_ts::little-64, len::little-32, timeout::little-32,
          sequence::little-32, flags::little-32, buf::binary-16, reply::8, rx_status::8,
          tx_status::8, arb::8, nack::8, low::8, err::8, _pad::8>>
      ) do
    %{
      tx_ts: tx_ts,
      rx_ts: rx_ts,
      timeout: timeout,
      sequence: sequence,
      flags: flags,
      msg: binary_part(buf, 0, min(len, 16)),
      reply: reply,
      rx_status: rx_status,
      tx_status: tx_status,
      tx_arb_lost_cnt: arb,
      tx_nack_cnt: nack,
      tx_low_drive_cnt: low,
      tx_error_cnt: err
    }
  end

  @doc """
  Classifies a struct read with `CEC_RECEIVE` on a non-blocking filehandle.

    * `:tx_result` - the outcome of our transmit (`sequence` set,
      `tx_status` set, `rx_status` 0)
    * `:rx_result` - the reply to our transmit (`sequence` set,
      `tx_status` 0, `rx_status` set)
    * `:unsolicited` - a message from the bus (`sequence` 0)
    * `:unknown` - any other combination
  """
  @spec classify(msg()) :: :tx_result | :rx_result | :unsolicited | :unknown
  def classify(%{sequence: 0}), do: :unsolicited
  def classify(%{tx_status: tx, rx_status: 0}) when tx != 0, do: :tx_result
  def classify(%{tx_status: 0, rx_status: rx}) when rx != 0, do: :rx_result
  def classify(_msg), do: :unknown

  @doc """
  Summarises a `tx_status` byte as one outcome.

  The kernel sets the cause bit (`NACK`, `ARB_LOST`, ...) together with
  `MAX_RETRIES` after the last retry, so the cause wins. `:none` means the
  struct isn't a transmit result.

      iex> Circuits.CEC.Struct.tx_outcome(0x01)
      :ok
      iex> Circuits.CEC.Struct.tx_outcome(0x24)
      :nack
  """
  @spec tx_outcome(byte()) ::
          :ok
          | :aborted
          | :timeout
          | :nack
          | :arb_lost
          | :low_drive
          | :error
          | :max_retries
          | :none
  def tx_outcome(0), do: :none
  def tx_outcome(status) when (status &&& 0x01) != 0, do: :ok

  def tx_outcome(status) do
    set = flags(:tx_status, status)

    Enum.find(
      [:aborted, :timeout, :nack, :arb_lost, :low_drive, :error, :max_retries],
      &(&1 in set)
    )
  end

  @doc """
  Summarises an `rx_status` byte as one outcome.

  A `<Feature Abort>` reply carries both `OK` and `FEATURE_ABORT`, so
  `:feature_abort` wins over `:ok`. `:none` means no reply status.

      iex> Circuits.CEC.Struct.rx_outcome(0x05)
      :feature_abort
  """
  @spec rx_outcome(byte()) :: :ok | :feature_abort | :aborted | :timeout | :none
  def rx_outcome(0), do: :none
  def rx_outcome(status) when (status &&& 0x04) != 0, do: :feature_abort
  def rx_outcome(status) when (status &&& 0x08) != 0, do: :aborted
  def rx_outcome(status) when (status &&& 0x02) != 0, do: :timeout
  def rx_outcome(status) when (status &&& 0x01) != 0, do: :ok
  def rx_outcome(_status), do: :none

  ## cec_log_addrs

  @doc "Size of `struct cec_log_addrs` in bytes."
  @spec log_addrs_size() :: 92
  def log_addrs_size, do: @log_addrs_size

  @doc """
  Builds a `struct cec_log_addrs` for `CEC_ADAP_S_LOG_ADDRS`.

  Fields default to 0, except `:log_addr` entries, which default to
  `0xFF` (invalid), so `encode_log_addrs([])` is the struct that clears the
  configuration (`num_log_addrs: 0`). A claim sets `:cec_version` (5 for
  1.4), `:vendor_id` (`0xFFFFFFFF` for none) and the type fields itself.
  List fields are padded to four entries. `:flags` may be an integer or a
  list of `flags(:log_addrs, _)` atoms. `:osd_name` is at most 14 bytes;
  callers truncate.
  """
  @spec encode_log_addrs(map() | keyword()) :: <<_::736>>
  def encode_log_addrs(fields) when is_list(fields), do: encode_log_addrs(Map.new(fields))

  def encode_log_addrs(f) when is_map(f) do
    osd_name = Map.get(f, :osd_name, "")
    features = Map.get(f, :features, [])

    if byte_size(osd_name) >= @osd_name_size do
      raise ArgumentError, "osd_name is #{byte_size(osd_name)} bytes; the limit is 14"
    end

    flags =
      case Map.get(f, :flags, 0) do
        list when is_list(list) -> flags_value(:log_addrs, list)
        int when is_integer(int) -> int
      end

    <<bytes4(Map.get(f, :log_addr, []), @invalid_log_addr)::binary-4,
      get(f, :log_addr_mask)::little-16, get(f, :cec_version)::8, get(f, :num_log_addrs)::8,
      get(f, :vendor_id)::little-32, flags::little-32, pad(osd_name, @osd_name_size)::binary,
      bytes4(Map.get(f, :primary_device_type, []), 0)::binary-4,
      bytes4(Map.get(f, :log_addr_type, []), 0)::binary-4,
      bytes4(Map.get(f, :all_device_types, []), 0)::binary-4,
      Enum.map_join(0..3, &pad(Enum.at(features, &1, ""), 12))::binary-48, 0::8>>
  end

  @doc "Decodes a `struct cec_log_addrs`."
  @spec decode_log_addrs(<<_::736>>) :: log_addrs()
  def decode_log_addrs(
        <<la::binary-4, mask::little-16, version::8, num::8, vendor::little-32, flags::little-32,
          osd::binary-15, prim::binary-4, types::binary-4, all::binary-4, features::binary-48,
          _pad::8>>
      ) do
    %{
      log_addr: :binary.bin_to_list(la),
      log_addr_mask: mask,
      cec_version: version,
      num_log_addrs: num,
      vendor_id: vendor,
      flags: flags,
      osd_name: cstring(osd),
      primary_device_type: :binary.bin_to_list(prim),
      log_addr_type: :binary.bin_to_list(types),
      all_device_types: :binary.bin_to_list(all),
      features: for(<<f::binary-12 <- features>>, do: f)
    }
  end

  @doc """
  The `log_addr_type` value for a device kind.

      iex> Circuits.CEC.Struct.log_addr_type(:playback)
      3
  """
  @spec log_addr_type(atom()) :: byte()
  for {name, value} <- @log_addr_types do
    def log_addr_type(unquote(name)), do: unquote(value)
  end

  @doc """
  The CEC 2.0 `all_device_types` bit for a device kind.

      iex> Circuits.CEC.Struct.all_device_type(:playback)
      0x10
  """
  @spec all_device_type(atom()) :: byte()
  for {name, value} <- @all_device_types do
    def all_device_type(unquote(name)), do: unquote(value)
  end

  ## cec_event

  @doc "Size of `struct cec_event` in bytes."
  @spec event_size() :: 80
  def event_size, do: @event_size

  @doc """
  Decodes a `struct cec_event`.

  `:raw` holds the 64-byte union. A `:state_change` adds `:phys_addr`
  (`0xFFFF` = invalid), `:log_addr_mask` and `:have_conn_info`; a
  `:lost_msgs` adds `:lost_msgs`. Unknown event numbers stay integers.
  """
  @spec decode_event(<<_::640>>) :: event()
  def decode_event(<<ts::little-64, type::little-32, flags::little-32, raw::binary-64>>) do
    base = %{ts: ts, event: event_name(type), flags: flags, raw: raw}

    case base.event do
      :state_change ->
        <<pa::little-16, mask::little-16, conn::little-16, _::binary>> = raw
        Map.merge(base, %{phys_addr: pa, log_addr_mask: mask, have_conn_info: conn})

      :lost_msgs ->
        <<lost::little-32, _::binary>> = raw
        Map.put(base, :lost_msgs, lost)

      _ ->
        base
    end
  end

  @doc """
  Builds a `struct cec_event`, mainly for fakes and tests.

  Uses `:raw` for the union if given, otherwise builds it from the
  event's own fields.
  """
  @spec encode_event(map() | keyword()) :: <<_::640>>
  def encode_event(fields) when is_list(fields), do: encode_event(Map.new(fields))

  def encode_event(%{event: event} = f) do
    type = if is_atom(event), do: Keyword.fetch!(@event_types, event), else: event

    raw =
      case f do
        %{raw: raw} when byte_size(raw) == 64 ->
          raw

        _ when type == 1 ->
          <<get(f, :phys_addr)::little-16, get(f, :log_addr_mask)::little-16,
            get(f, :have_conn_info)::little-16, 0::size(58 * 8)>>

        _ when type == 2 ->
          <<get(f, :lost_msgs)::little-32, 0::size(60 * 8)>>

        _ ->
          <<0::size(64 * 8)>>
      end

    flags =
      case Map.get(f, :flags, 0) do
        list when is_list(list) -> flags_value(:event, list)
        int when is_integer(int) -> int
      end

    <<get(f, :ts)::little-64, type::little-32, flags::little-32, raw::binary>>
  end

  ## cec_caps

  @doc "Size of `struct cec_caps` in bytes."
  @spec caps_size() :: 76
  def caps_size, do: @caps_size

  @doc "Decodes a `struct cec_caps`. Use `flags(:caps, caps.capabilities)` for the bits."
  @spec decode_caps(<<_::608>>) :: caps()
  def decode_caps(
        <<driver::binary-32, name::binary-32, avail::little-32, caps::little-32,
          version::little-32>>
      ) do
    %{
      driver: cstring(driver),
      name: cstring(name),
      available_log_addrs: avail,
      capabilities: caps,
      version: version
    }
  end

  @doc "Builds a `struct cec_caps`, mainly for fakes and tests."
  @spec encode_caps(map() | keyword()) :: <<_::608>>
  def encode_caps(fields) when is_list(fields), do: encode_caps(Map.new(fields))

  def encode_caps(f) when is_map(f) do
    caps =
      case Map.get(f, :capabilities, 0) do
        list when is_list(list) -> flags_value(:caps, list)
        int when is_integer(int) -> int
      end

    <<pad(Map.get(f, :driver, ""), 32)::binary, pad(Map.get(f, :name, ""), 32)::binary,
      get(f, :available_log_addrs)::little-32, caps::little-32, get(f, :version)::little-32>>
  end

  ## cec_connector_info

  @doc "Size of `struct cec_connector_info` in bytes."
  @spec connector_info_size() :: 68
  def connector_info_size, do: @connector_info_size

  @doc "Decodes a `struct cec_connector_info`. A DRM connector adds `:card_no` and `:connector_id`."
  @spec decode_connector_info(<<_::544>>) :: connector_info()
  def decode_connector_info(<<type::little-32, raw::binary-64>>) do
    case type do
      0 ->
        %{type: :none, raw: raw}

      1 ->
        <<card::little-32, conn::little-32, _::binary>> = raw
        %{type: :drm, card_no: card, connector_id: conn, raw: raw}

      other ->
        %{type: other, raw: raw}
    end
  end

  @doc "Builds a `struct cec_connector_info`, mainly for fakes and tests."
  @spec encode_connector_info(map() | keyword()) :: <<_::544>>
  def encode_connector_info(fields) when is_list(fields),
    do: encode_connector_info(Map.new(fields))

  def encode_connector_info(%{type: type} = f) do
    raw =
      case f do
        %{raw: raw} when byte_size(raw) == 64 -> raw
        %{type: :drm} -> <<get(f, :card_no)::little-32, get(f, :connector_id)::little-32, 0::448>>
        _ -> <<0::512>>
      end

    type_value =
      case type do
        :none -> 0
        :drm -> 1
        int when is_integer(int) -> int
      end

    <<type_value::little-32, raw::binary>>
  end

  ## Scalars, modes and flags

  @doc "Decodes the `__u16` physical address from `CEC_ADAP_G_PHYS_ADDR`."
  @spec decode_phys_addr(<<_::16>>) :: 0..0xFFFF
  def decode_phys_addr(<<pa::little-16>>), do: pa

  @doc "Decodes the `__u32` mode from `CEC_G_MODE`."
  @spec decode_u32(<<_::32>>) :: non_neg_integer()
  def decode_u32(<<value::little-32>>), do: value

  @doc """
  Builds a `CEC_S_MODE` value from an initiator and a follower mode.

      iex> Circuits.CEC.Struct.mode(:initiator, :exclusive)
      0x21
      iex> Circuits.CEC.Struct.mode(:initiator, :follower)
      0x11
  """
  @spec mode(initiator_mode(), follower_mode()) :: byte()
  def mode(initiator, follower) do
    Keyword.fetch!(@initiator_modes, initiator) ||| Keyword.fetch!(@follower_modes, follower)
  end

  @doc """
  Splits a mode value into its initiator and follower parts. Unknown parts
  stay integers.

      iex> Circuits.CEC.Struct.decode_mode(0x21)
      {:initiator, :exclusive}
  """
  @spec decode_mode(non_neg_integer()) ::
          {initiator_mode() | non_neg_integer(), follower_mode() | non_neg_integer()}
  def decode_mode(value) do
    {lookup(@initiator_modes, value &&& 0x0F), lookup(@follower_modes, value &&& 0xF0)}
  end

  @doc """
  Names the bits set in a flags field. Bits without a name are dropped.

      iex> Circuits.CEC.Struct.flags(:tx_status, 0x24)
      [:nack, :max_retries]
  """
  @spec flags(flag_kind(), non_neg_integer()) :: [atom()]
  def flags(kind, value) when is_integer(value) do
    for {name, bit} <- Map.fetch!(@flag_tables, kind), (value &&& bit) != 0, do: name
  end

  @doc """
  Combines flag names into a flags value.

      iex> Circuits.CEC.Struct.flags_value(:log_addrs, [:allow_unreg_fallback])
      1
  """
  @spec flags_value(flag_kind(), [atom()]) :: non_neg_integer()
  def flags_value(kind, names) when is_list(names) do
    table = Map.fetch!(@flag_tables, kind)
    Enum.reduce(names, 0, &(Keyword.fetch!(table, &1) ||| &2))
  end

  ## Helpers

  defp get(map, key), do: Map.get(map, key, 0)

  defp event_name(type), do: lookup(@event_types, type)

  defp lookup(table, value) do
    case List.keyfind(table, value, 1) do
      {name, ^value} -> name
      nil -> value
    end
  end

  defp bytes4(list, fill) when length(list) <= 4 do
    list |> Enum.concat(List.duplicate(fill, 4 - length(list))) |> :binary.list_to_bin()
  end

  defp pad(bin, size) when byte_size(bin) <= size,
    do: bin <> <<0::size((size - byte_size(bin)) * 8)>>

  defp cstring(bin), do: bin |> :binary.split(<<0>>) |> hd()
end
