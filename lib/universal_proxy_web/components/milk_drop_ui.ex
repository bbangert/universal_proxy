defmodule UniversalProxyWeb.Components.MilkDropUI do
  @moduledoc """
  Pieces shared by the Audio tab's MilkDrop section
  (`UniversalProxyWeb.MilkDropComponent`) and the preset browser
  (`UniversalProxyWeb.MilkDropPresetsLive`).
  """

  use Phoenix.Component

  import UniversalProxyWeb.Components.Icons

  alias UniversalProxy.MilkDrop

  @doc """
  Whether the MilkDrop UI shows: `UniversalProxy.MilkDrop.enabled?/0`,
  unless a boolean `:milkdrop_ui_override` app env says otherwise (host
  tests, where the flag is compile-time false).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    case Application.get_env(:universal_proxy, :milkdrop_ui_override) do
      override when is_boolean(override) -> override
      _ -> MilkDrop.enabled?()
    end
  end

  @doc "A skip reason (the renderer's, or the pack sweep's) for people."
  @spec reason_label(String.t() | nil) :: String.t()
  def reason_label("too_bright"), do: "Too bright"
  def reason_label("budget"), do: "Too slow for this device"
  def reason_label("compile_error"), do: "Shader failed to compile"
  def reason_label("shader_error"), do: "Shader failed to compile"
  def reason_label("register_allocate"), do: "Too complex for the GPU"
  def reason_label("load_failed"), do: "Failed to load"
  def reason_label("draw_dropped"), do: "Failed to draw"
  def reason_label("device_reset"), do: "Reset the device"
  def reason_label("gpu_hang"), do: "Hung the GPU"
  def reason_label("hang"), do: "Froze the renderer"
  def reason_label("crashed"), do: "Crashed the renderer"
  def reason_label(nil), do: "Unknown reason"
  def reason_label(reason), do: reason

  @doc "`n` with thousands separators (`1,664`)."
  @spec delimit(non_neg_integer()) :: String.t()
  def delimit(n) when is_integer(n) and n >= 0 do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "`\"<n> <noun>\"`, with `noun` pluralised by an `s` unless `n` is 1."
  @spec count_label(non_neg_integer(), String.t()) :: String.t()
  def count_label(1, noun), do: "1 #{noun}"
  def count_label(n, noun), do: "#{delimit(n)} #{noun}s"

  @doc "The photosensitivity warning shown wherever fast-flashing presets can be let in."
  attr(:id, :string, default: nil)
  attr(:class, :string, default: nil)

  attr(:lead, :string,
    default:
      "These presets flash rapidly and may trigger seizures in people with photosensitive epilepsy."
  )

  slot(:inner_block)

  def photosensitivity_warning(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "p-[10px_12px] rounded-md bg-warning-soft text-warning text-sm font-medium flex items-start gap-2",
        @class
      ]}
    >
      <.icon name={:alert} size={16} stroke={2.0} class="mt-0.5 flex-none" />
      <span>
        {@lead} {render_slot(@inner_block)}
      </span>
    </div>
    """
  end
end
