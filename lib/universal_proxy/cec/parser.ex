defmodule UniversalProxy.Cec.Parser do
  @moduledoc """
  Decodes `cec-ctl` text output into records.

  Two shapes come out of cec-ctl, both line-oriented:

  Monitor stream (`cec-ctl -m`), one header line per message followed by one
  tab-indented line per argument, plus event lines:

      Received from Audio System to Playback Device 1 (5 to 4): REPORT_POWER_STATUS (0x90):
      \tpwr-state: On (0x00)
      Transmitted by Playback Device 1 to TV (4 to 0): IMAGE_VIEW_ON (0x04)
      Event: State Change: PA: 1.0.0.0, LA mask: 0x0010

  One-shot reply (`cec-ctl --to 5 --give-device-power-status`), where the
  reply header carries only the initiator and the opcode sits on its own
  indented line:

          Received from Audio System (5):
          REPORT_POWER_STATUS (0x90):
      \tpwr-state: On (0x00)
      \tSequence: 1 Tx Timestamp: 12:00:00.000 Rx Timestamp: 12:00:00.100

  `feed/2` is the streaming entry point (keeps the record under construction
  across lines); `parse/1` runs a whole string through it.

  Records:

    * `%{type: :message, direction: :received | :transmitted, from: la, to: la | :all,
       opcode: "REPORT_POWER_STATUS", code: 0x90, args: %{"pwr-state" => %{text: "On", value: 0}}}`
    * `%{type: :event, kind: :state_change, phys_addr: "1.0.0.0", la_mask: 0x0010}`
    * `%{type: :event, kind: :other, text: "Lost 3 messages"}`
  """

  @type arg :: %{text: String.t(), value: non_neg_integer() | nil}
  @type entry :: %{required(:type) => :message | :event, optional(atom()) => term()}
  @opaque state :: %{current: entry() | nil}

  @header_re ~r/^(Received from|Transmitted by) (.+?) to (.+?) \((\d+) to (\d+)\): ([A-Z0-9_]+) \(0x([0-9a-fA-F]{2})\):?\s*$/
  @reply_re ~r/^\s*Received from (.+?) \((\d+)\):\s*$/
  @opcode_re ~r/^\s*([A-Z][A-Z0-9_]*) \(0x([0-9a-fA-F]{2})\):?\s*$/
  @arg_re ~r/^\s+([a-z][a-z0-9-]*): (.*?)(?: \(0x([0-9a-fA-F]+)(?:, [^)]*)?\))?\s*$/
  @event_re ~r/^(?:Initial )?(?:\d\d:\d\d:\d\d\.\d+: )?Event: (.*?)\s*$/
  @state_change_re ~r/^State Change: PA: ([0-9a-f]\.[0-9a-f]\.[0-9a-f]\.[0-9a-f]), LA mask: 0x([0-9a-fA-F]{4})/
  @phys_addr_re ~r/^\s*Physical Address\s*: ([0-9a-f]\.[0-9a-f]\.[0-9a-f]\.[0-9a-f])/m
  @log_addr_re ~r/^\s*Logical Address\s*: (\d+) \(/m

  @doc "Empty streaming state."
  @spec new() :: state()
  def new, do: %{current: nil}

  @doc "Parse a whole output blob into records."
  @spec parse(String.t()) :: [entry()]
  def parse(text) when is_binary(text) do
    {state, records} =
      text
      |> String.split(["\r\n", "\n"])
      |> Enum.reduce({new(), []}, fn line, {st, acc} ->
        {st, out} = feed(st, line)
        {st, Enum.reverse(out, acc)}
      end)

    {_st, out} = finish(state)
    Enum.reverse(Enum.reverse(out, records))
  end

  @doc "Feed one line; returns the new state and any records completed by it."
  @spec feed(state(), String.t()) :: {state(), [entry()]}
  def feed(%{current: cur} = state, line) do
    case classify(line, cur) do
      {:event, rec} -> {%{state | current: nil}, flushed(cur) ++ [rec]}
      {:start, rec} -> {%{state | current: rec}, flushed(cur)}
      {:opcode, opcode, code} -> {%{state | current: %{cur | opcode: opcode, code: code}}, []}
      {:arg, name, arg} -> {%{state | current: put_in(cur, [:args, name], arg)}, []}
      :skip -> {state, []}
      :break -> {%{state | current: nil}, flushed(cur)}
    end
  end

  @doc "Flush the record under construction, if any."
  @spec finish(state()) :: {state(), [entry()]}
  def finish(%{current: cur}), do: {new(), flushed(cur)}

  @doc "First received message in a one-shot's output, or `nil`."
  @spec reply(String.t()) :: entry() | nil
  def reply(text) do
    text
    |> parse()
    |> Enum.find(
      &match?(%{type: :message, direction: :received, opcode: op} when is_binary(op), &1)
    )
  end

  @doc "Physical and logical address from a Driver Info dump."
  @spec driver_info(String.t()) :: %{phys_addr: String.t() | nil, logical_address: 0..15 | nil}
  def driver_info(text) do
    phys_addr =
      case Regex.run(@phys_addr_re, text) do
        [_, pa] -> pa
        _ -> nil
      end

    logical_address =
      case Regex.run(@log_addr_re, text) do
        [_, la] -> String.to_integer(la)
        _ -> nil
      end

    %{phys_addr: phys_addr, logical_address: logical_address}
  end

  @doc "Decode a REPORT_POWER_STATUS record's state."
  @spec power_state(entry()) :: :on | :standby | :to_on | :to_standby | :unknown
  def power_state(%{args: %{"pwr-state" => %{value: v}}}) do
    case v do
      0 -> :on
      1 -> :standby
      2 -> :to_on
      3 -> :to_standby
      _ -> :unknown
    end
  end

  def power_state(_), do: :unknown

  @doc "Decode a REPORT_AUDIO_STATUS record into volume (0..100 or nil) and mute."
  @spec audio_status(entry()) :: %{volume: 0..100 | nil, muted: boolean()}
  def audio_status(%{args: args}) do
    vol =
      case args do
        %{"aud-vol-status" => %{value: v}} when is_integer(v) and v in 0..100 -> v
        _ -> nil
      end

    muted = match?(%{"aud-mute-status" => %{value: 1}}, args)
    %{volume: vol, muted: muted}
  end

  @doc "An unplugged HDMI link reports the invalid physical address f.f.f.f."
  @spec valid_phys_addr?(String.t() | nil) :: boolean()
  def valid_phys_addr?(pa), do: is_binary(pa) and pa != "f.f.f.f"

  # ── private ───────────────────────────────────────────────────────────

  # One line, classified against the record under construction (`cur`).
  # Order matters: an event or a header always starts fresh; an indented
  # opcode line only completes a reply header that has no opcode yet; any
  # other indented line is cec-ctl detail we don't model (Sequence, Driver
  # Info rows); a non-indented line we don't recognise ends the record.
  defp classify(line, cur) do
    cond do
      match = Regex.run(@event_re, line) ->
        {:event, event(Enum.at(match, 1))}

      match = Regex.run(@header_re, line) ->
        {:start, header(match)}

      match = Regex.run(@reply_re, line) ->
        {:start, reply_header(match)}

      match = is_map(cur) and is_nil(cur.opcode) and Regex.run(@opcode_re, line) ->
        opcode(match)

      match = is_map(cur) and Regex.run(@arg_re, line) ->
        arg(match)

      String.starts_with?(line, [" ", "\t"]) ->
        :skip

      true ->
        :break
    end
  end

  defp header([_, dir, _from_name, to_name, from, to, opcode, code]) do
    %{
      type: :message,
      direction: if(dir == "Received from", do: :received, else: :transmitted),
      from: String.to_integer(from),
      to: if(to_name == "all", do: :all, else: String.to_integer(to)),
      opcode: opcode,
      code: String.to_integer(code, 16),
      args: %{}
    }
  end

  defp reply_header([_, _from_name, from]) do
    %{
      type: :message,
      direction: :received,
      from: String.to_integer(from),
      to: nil,
      opcode: nil,
      code: nil,
      args: %{}
    }
  end

  defp opcode([_, opcode, code]), do: {:opcode, opcode, String.to_integer(code, 16)}

  defp arg([_, name, text | rest]),
    do: {:arg, name, %{text: text, value: arg_value(text, List.first(rest))}}

  defp flushed(nil), do: []
  defp flushed(%{opcode: nil}), do: []
  defp flushed(rec), do: [rec]

  defp event(text) do
    case Regex.run(@state_change_re, text) do
      [_, pa, mask] ->
        %{type: :event, kind: :state_change, phys_addr: pa, la_mask: String.to_integer(mask, 16)}

      _ ->
        %{type: :event, kind: :other, text: text}
    end
  end

  defp arg_value(_text, hex) when is_binary(hex) and hex != "", do: String.to_integer(hex, 16)

  defp arg_value(text, _) do
    case Integer.parse(text) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
