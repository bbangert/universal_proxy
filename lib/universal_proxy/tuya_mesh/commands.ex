defmodule UniversalProxy.TuyaMesh.Commands do
  @moduledoc """
  Home Assistant light commands to Tuya mesh DP batches, and DPs back to a
  light state. Pure: no I/O.

  ## Mapping

  | HA (`LightCommandRequest`) | DPs |
  |---|---|
  | `state: false` | only `on: false` (DP1); everything else is dropped |
  | `state: true` | `on: true` (DP1) |
  | colour-temperature mode | `mode: :white` (DP2 0) |
  | `color_temperature` (mireds) | `temp:` (DP4) 0..1000, linear over the settings' range: `max_mireds` (warm) → 0, `min_mireds` (cool) → 1000; `invert` flips it |
  | `brightness` 0..1, white mode | `brightness:` (DP3) 10..1000, never below 10 |
  | RGB mode | `mode: :colour` (DP2 1) |
  | `rgb` + `color_brightness` + `brightness` | `colour: {h, s, v}` (DP11): hue and saturation from the RGB, `v` (1..100) = brightness × colour brightness × the RGB's largest channel |
  | transition, flash, effect, white channels | ignored |

  The mode is the command's `color_mode` (colour temperature or RGB), else
  implied by a colour temperature or RGB in it. Without either, a
  brightness goes where the light's current mode (`current`, a DP map like
  `Lights.status/2`'s `dps`) keeps it: the colour's `v` in colour mode
  (with the current hue and saturation), else DP3. A colour brightness
  alone sets the colour's `v` the same way in colour mode. `v` is always
  computed from the brightness and colour brightness components
  (`components/2`), the supplied ones replacing the kept ones, so repeating
  a command leaves it unchanged. A colour command
  without RGB takes the current hue and saturation, and without a
  brightness the current one. The bulbs' colour mode has no separate
  brightness, so DP3 is never sent with a colour.

  ## Batches

  A frame carries at most 16 bytes of DPs (`Dp.encode/1`): bool and enum
  DPs take 3, value and colour DPs 6. Entries are ordered on (when the
  command switches the light on), mode, its value (temperature or colour),
  then brightness, and packed greedily in that order, so a command is as
  few frames as its size allows (at most two). A light switched on lights
  in the first frame, already in its mode and temperature or colour
  (`[on, mode, temp]` is 12 bytes, `[on, mode, colour]` too); a brightness
  that doesn't fit follows in the next. Off is DP1 alone.
  """

  require Logger

  alias Espex.Proto
  alias UniversalProxy.TuyaBeaconMesh.{Control, Dp}

  @max_bytes 16

  @dp_ids %{on: 1, mode: 2, brightness: 3, temp: 4, colour: 11}

  @type entry ::
          {:on, boolean()}
          | {:mode, :white | :colour}
          | {:brightness, 10..1000}
          | {:temp, 0..1000}
          | {:colour, {0..359, 0..100, 0..100}}
  @type batch :: [entry()]
  @type settings :: %{min_mireds: pos_integer(), max_mireds: pos_integer(), invert: boolean()}
  @typedoc """
  DP id → decoded value, as `Lights` keeps a bulb's reported DPs, plus
  optionally the `:brightness`, `:color_brightness` and `:peak` components
  (`components/2`).
  """
  @type dps :: %{optional(pos_integer() | :brightness | :color_brightness | :peak) => term()}
  @type components :: %{
          optional(:brightness) => float(),
          optional(:color_brightness) => float(),
          optional(:peak) => float()
        }

  @doc """
  The DP batches for `request`, in send order, each at most 16 bytes
  encoded. `[]` when nothing in it maps to a DP.
  """
  @spec batches(Proto.LightCommandRequest.t(), settings(), dps()) :: [batch()]
  def batches(%Proto.LightCommandRequest{} = request, settings, current \\ %{}) do
    request |> entries(settings, current) |> split()
  end

  @doc "The ordered DP entries for `request`, before splitting."
  @spec entries(Proto.LightCommandRequest.t(), settings(), dps()) :: [entry()]
  def entries(%Proto.LightCommandRequest{} = request, settings, current \\ %{}) do
    log_ignored(request)

    if request.has_state and request.state == false do
      [on: false]
    else
      on_entries(request) ++ mode_entries(request, settings, current)
    end
  end

  @doc """
  Packs `entries` in order into batches of at most 16 encoded bytes.
  Entries must be valid friendly DPs (`Control.friendly_dps/1`).
  """
  @spec split([entry()]) :: [batch()]
  def split(entries) do
    entries
    |> Enum.reduce({[], [], 0}, fn entry, {done, batch, size} ->
      bytes = entry_size(entry)

      if batch != [] and size + bytes > @max_bytes,
        do: {[Enum.reverse(batch) | done], [entry], bytes},
        else: {done, [entry | batch], size + bytes}
    end)
    |> then(fn
      {done, [], _size} -> Enum.reverse(done)
      {done, batch, _size} -> Enum.reverse([Enum.reverse(batch) | done])
    end)
  end

  @doc "Encoded size of one entry, in bytes."
  @spec entry_size(entry()) :: pos_integer()
  def entry_size(entry) do
    {:ok, dps} = Control.friendly_dps([entry])
    {:ok, bin} = Dp.encode(dps)
    byte_size(bin)
  end

  @doc "The DP id an entry sets."
  @spec dp_id(entry()) :: pos_integer()
  def dp_id({key, _value}), do: Map.fetch!(@dp_ids, key)

  @doc """
  What the entries set, as a DP map in the form `Lights` decodes reports
  into (a colour is its raw `<<h::16, s, v>>`): later entries win.
  """
  @spec expected([entry()]) :: dps()
  def expected(entries) do
    {:ok, dps} = Control.friendly_dps(entries)
    Map.new(dps, fn {id, _type, value} -> {id, value} end)
  end

  @doc """
  The entries `dps` doesn't show yet: those whose DP is missing from it or
  holds another value.
  """
  @spec unconfirmed([entry()], dps()) :: [entry()]
  def unconfirmed(entries, dps) do
    Enum.reject(entries, fn entry ->
      [{id, value}] = Map.to_list(expected([entry]))
      Map.get(dps, id) == value
    end)
  end

  # ── Mode, value, brightness ──────────────────────────────────────────

  defp mode_entries(request, settings, current) do
    case requested_mode(request) do
      :white -> [mode: :white] ++ temp_entries(request, settings) ++ brightness_entries(request)
      :colour -> [mode: :colour] ++ colour_entries(request, current)
      nil -> keep_mode_entries(request, current)
    end
  end

  defp requested_mode(%{has_color_mode: true, color_mode: :COLOR_MODE_COLOR_TEMPERATURE}),
    do: :white

  defp requested_mode(%{has_color_mode: true, color_mode: :COLOR_MODE_RGB}), do: :colour
  defp requested_mode(%{has_rgb: true}), do: :colour
  defp requested_mode(%{has_color_temperature: true}), do: :white
  defp requested_mode(_request), do: nil

  defp temp_entries(%{has_color_temperature: true, color_temperature: m}, settings)
       when is_number(m),
       do: [temp: mireds_to_temp(m, settings)]

  defp temp_entries(_request, _settings), do: []

  defp brightness_entries(%{has_brightness: true, brightness: b}) when is_number(b),
    do: [brightness: brightness_dp(b)]

  defp brightness_entries(_request), do: []

  # A brightness or colour brightness alone stays in the light's current
  # mode (a colour brightness only means something in colour mode).
  defp keep_mode_entries(request, current) do
    with true <- brightness?(request) or colour_brightness?(request),
         :colour <- current_mode(current),
         {_h, _s} <- current_hs(current) do
      colour_entries(request, current)
    else
      _ -> brightness_entries(request)
    end
  end

  defp colour_entries(request, current) do
    hs = if request.has_rgb, do: rgb_hs(request), else: current_hs(current)

    cond do
      hs == nil ->
        if brightness?(request) or colour_brightness?(request) do
          Logger.debug("TuyaMesh.Commands: colour brightness without a known colour; ignored")
        end

        []

      request.has_rgb or brightness?(request) or colour_brightness?(request) ->
        {h, s} = hs
        [colour: {h, s, colour_v(request, current)}]

      true ->
        []
    end
  end

  defp brightness?(%{has_brightness: true, brightness: b}) when is_number(b), do: true
  defp brightness?(_request), do: false

  defp colour_brightness?(%{has_color_brightness: true, color_brightness: b}) when is_number(b),
    do: true

  defp colour_brightness?(_request), do: false

  # v = brightness × colour brightness × the RGB's largest channel (HA
  # normalises the RGB and sends its largest channel as colour brightness).
  # Both components come from the stored ones, never from v, which already
  # holds their product.
  defp colour_v(request, current) do
    {master, colour, peak} = resolve(request, current)
    (master * colour * peak * 100) |> round() |> clamp(1, 100)
  end

  defp resolve(request, current) do
    master = if brightness?(request), do: request.brightness, else: current_master(current)

    colour =
      cond do
        colour_brightness?(request) -> request.color_brightness
        is_number(Map.get(current, :color_brightness)) -> current.color_brightness
        true -> 1.0
      end

    peak =
      cond do
        request.has_rgb -> rgb_peak(request)
        is_number(Map.get(current, :peak)) -> current.peak
        true -> 1.0
      end

    {unit(master), unit(colour), unit(peak)}
  end

  @doc """
  The light's colour components after `request`: `%{brightness:,
  color_brightness:, peak:}` (each 0..1; `peak` is the RGB's largest
  channel), for the caller to keep with the light's DPs (`current` takes
  them under those atom keys) so a later colour is computed from them
  rather than from the already-scaled `v`. Unknown ones start as
  `color_brightness` and `peak` 1 and the current brightness (DP3, or `v`
  in colour mode). `%{}` when the request changes none, or turns the light
  off. Keep them with `committed/2`.
  """
  @spec components(Proto.LightCommandRequest.t(), dps()) :: components()
  def components(%Proto.LightCommandRequest{} = request, current \\ %{}) do
    cond do
      request.has_state and request.state == false ->
        %{}

      brightness?(request) or colour_brightness?(request) or request.has_rgb ->
        {master, colour, peak} = resolve(request, current)
        %{brightness: master, color_brightness: colour, peak: peak}

      true ->
        %{}
    end
  end

  @doc """
  Keeps the components (`components/2`) true to `reported`, DPs a bulb
  reported (already merged into `dps`). The light's mode (DP2 in `dps`)
  picks the DP that counts: in colour mode, a reported colour whose `v`
  the kept components don't produce resets them to brightness `v`/100,
  colour brightness and peak 1; otherwise a reported DP3 sets the
  brightness. A reported mode (DP2) re-derives them the same way from the
  new mode's DP, so a switch never keeps the old mode's brightness.
  Anything else leaves them.
  """
  @spec reconcile_components(dps(), dps()) :: dps()
  def reconcile_components(dps, reported) do
    # Only the DP of the light's mode says its brightness: a merged report
    # can carry an old colour while white, or an old DP3 while in colour.
    # A reported mode (a switch) re-derives it from that mode's DP.
    mode_reported? = Map.has_key?(reported, 2)

    case {Map.get(dps, 2), Map.get(dps, 11), Map.get(dps, 3)} do
      {1, <<_h::16, _s, v>>, _dp3} when v in 0..100 ->
        if Map.has_key?(reported, 11) or mode_reported?,
          do: colour_components(dps, v),
          else: dps

      {mode, _colour, dp3} when mode != 1 and is_integer(dp3) ->
        if Map.has_key?(reported, 3) or mode_reported?,
          do: Map.put(dps, :brightness, clamp(dp3, 10, 1000) / 1000),
          else: dps

      _other ->
        dps
    end
  end

  defp colour_components(dps, v) do
    if components_give?(dps, v),
      do: dps,
      else: Map.merge(dps, %{brightness: v / 100, color_brightness: 1.0, peak: 1.0})
  end

  defp components_give?(%{brightness: b, color_brightness: cb} = dps, v)
       when is_number(b) and is_number(cb) do
    peak = Map.get(dps, :peak, 1.0)
    (b * cb * peak * 100) |> round() |> clamp(1, 100) == clamp(v, 1, 100)
  end

  defp components_give?(_dps, _v), do: false

  @doc """
  The components that an accepted batch setting `sent` (a DP map) makes
  true on the light: all of them with a colour (DP11), the brightness
  alone with DP3, none otherwise. A component whose DP never went out
  must not be kept, or a later colour would be computed from it.
  """
  @spec committed(components(), dps()) :: components()
  def committed(components, sent) do
    cond do
      Map.has_key?(sent, 11) -> Map.take(components, [:brightness, :color_brightness, :peak])
      Map.has_key?(sent, 3) -> Map.take(components, [:brightness])
      true -> %{}
    end
  end

  defp on_entries(%{has_state: true, state: true}), do: [on: true]
  defp on_entries(_request), do: []

  defp current_mode(current) do
    case Map.get(current, 2) do
      0 -> :white
      1 -> :colour
      _other -> nil
    end
  end

  defp current_hs(current) do
    case Map.get(current, 11) do
      <<h::16, s, _v>> when h in 0..359 and s in 0..100 -> {h, s}
      _other -> nil
    end
  end

  defp current_master(%{brightness: b}) when is_number(b), do: b

  defp current_master(current) do
    case {current_mode(current), Map.get(current, 11), Map.get(current, 3)} do
      {:colour, <<_h::16, _s, v>>, _bri} when v in 0..100 -> v / 100
      {_mode, _colour, bri} when is_integer(bri) -> clamp(bri, 10, 1000) / 1000
      _unknown -> 1.0
    end
  end

  defp log_ignored(request) do
    if request.has_effect,
      do: Logger.debug("TuyaMesh.Commands: effects aren't supported; ignored")

    if request.has_white or request.has_cold_white or request.has_warm_white,
      do: Logger.debug("TuyaMesh.Commands: white channels aren't supported; ignored")

    :ok
  end

  # ── Conversions ──────────────────────────────────────────────────────

  @doc "HA brightness 0..1 → DP3 10..1000."
  @spec brightness_dp(number()) :: 10..1000
  def brightness_dp(b), do: (b * 1000) |> round() |> clamp(10, 1000)

  @doc """
  Mireds → DP4 0..1000: `max_mireds` (warm) → 0, `min_mireds` (cool) →
  1000, linear between, clamped; `invert` flips it.
  """
  @spec mireds_to_temp(number(), settings()) :: 0..1000
  def mireds_to_temp(mireds, %{min_mireds: min, max_mireds: max} = settings) do
    temp = ((max - mireds) * 1000 / (max - min)) |> round() |> clamp(0, 1000)
    if settings.invert, do: 1000 - temp, else: temp
  end

  @doc "DP4 0..1000 → mireds, the inverse of `mireds_to_temp/2`."
  @spec temp_to_mireds(integer(), settings()) :: float()
  def temp_to_mireds(temp, %{min_mireds: min, max_mireds: max} = settings) do
    temp = clamp(temp, 0, 1000)
    temp = if settings.invert, do: 1000 - temp, else: temp
    max - temp * (max - min) / 1000
  end

  @doc "RGB (0..1 each) → `{hue 0..359, saturation 0..100}`."
  @spec rgb_to_hs(number(), number(), number()) :: {0..359, 0..100}
  def rgb_to_hs(r, g, b) do
    {r, g, b} = {unit(r), unit(g), unit(b)}
    peak = max(r, max(g, b))
    delta = peak - min(r, min(g, b))

    hue =
      cond do
        delta == 0 -> 0.0
        peak == r -> 60 * fmod((g - b) / delta, 6)
        peak == g -> 60 * ((b - r) / delta + 2)
        true -> 60 * ((r - g) / delta + 4)
      end

    sat = if peak == 0, do: 0, else: round(100 * delta / peak)
    {rem(round(hue), 360), clamp(sat, 0, 100)}
  end

  @doc "`{hue, saturation}` → RGB (0..1 each) at full value."
  @spec hs_to_rgb(0..359, 0..100) :: {float(), float(), float()}
  def hs_to_rgb(h, s) do
    s = s / 100
    c = s
    x = c * (1 - abs(fmod(h / 60, 2) - 1))
    m = 1 - c

    {r, g, b} =
      cond do
        h < 60 -> {c, x, 0}
        h < 120 -> {x, c, 0}
        h < 180 -> {0, c, x}
        h < 240 -> {0, x, c}
        h < 300 -> {x, 0, c}
        true -> {c, 0, x}
      end

    {(r + m) * 1.0, (g + m) * 1.0, (b + m) * 1.0}
  end

  defp rgb_hs(request), do: rgb_to_hs(request.red, request.green, request.blue)

  defp rgb_peak(request),
    do: max(unit(request.red), max(unit(request.green), unit(request.blue)))

  defp unit(v) when is_number(v), do: clamp(v * 1.0, 0.0, 1.0)
  defp unit(_v), do: 0.0

  defp fmod(a, n) do
    r = a - n * Float.floor(a / n)
    if r >= n, do: r - n, else: r
  end

  defp clamp(v, lo, hi), do: v |> max(lo) |> min(hi)

  # ── State ────────────────────────────────────────────────────────────

  @doc """
  The `LightStateResponse` for a light whose DPs are `dps`, or `nil` while
  its on/off (DP1) is unknown: the protocol has no unknown light state.
  Colour mode (DP2 1 with a colour) reports RGB at full value with the
  colour's `v` as the brightness (or the kept `:brightness` and
  `:color_brightness` components, see `components/2`, with the RGB scaled
  by the kept `:peak`); anything else reports colour
  temperature with DP3's brightness. Unknown values take HA-neutral
  defaults (full brightness, white, mid-range temperature).
  """
  @spec state_response(dps(), settings(), non_neg_integer(), non_neg_integer()) ::
          Proto.LightStateResponse.t() | nil
  def state_response(dps, settings, key, device_id) do
    case Map.get(dps, 1) do
      on when is_boolean(on) ->
        temp = Map.get(dps, 4)

        mireds =
          if is_integer(temp),
            do: temp_to_mireds(temp, settings),
            else: (settings.min_mireds + settings.max_mireds) / 2

        base = %Proto.LightStateResponse{
          key: key,
          device_id: device_id,
          state: on,
          color_temperature: mireds * 1.0,
          color_brightness: 1.0,
          red: 1.0,
          green: 1.0,
          blue: 1.0
        }

        dps |> with_components(base) |> with_mode(current_mode(dps), dps)

      _unknown ->
        nil
    end
  end

  defp with_components(dps, response) do
    case Map.get(dps, :color_brightness) do
      cb when is_number(cb) -> %{response | color_brightness: cb * 1.0}
      _unknown -> response
    end
  end

  defp with_mode(response, :colour, dps) do
    case Map.get(dps, 11) do
      <<h::16, s, v>> when h in 0..359 and s in 0..100 ->
        peak =
          case Map.get(dps, :peak) do
            p when is_number(p) -> p
            _unknown -> 1.0
          end

        {r, g, b} = hs_to_rgb(h, s)
        {r, g, b} = {r * peak, g * peak, b * peak}

        brightness =
          case Map.get(dps, :brightness) do
            master when is_number(master) -> master * 1.0
            _unknown -> clamp(v, 0, 100) / 100
          end

        %{
          response
          | color_mode: :COLOR_MODE_RGB,
            brightness: brightness,
            red: r,
            green: g,
            blue: b
        }

      _no_colour ->
        with_mode(response, :white, dps)
    end
  end

  defp with_mode(response, _mode, dps) do
    brightness =
      case Map.get(dps, 3) do
        bri when is_integer(bri) -> clamp(bri, 10, 1000) / 1000
        _unknown -> 1.0
      end

    %{response | color_mode: :COLOR_MODE_COLOR_TEMPERATURE, brightness: brightness}
  end
end
