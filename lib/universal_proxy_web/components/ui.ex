defmodule UniversalProxyWeb.Components.UI do
  @moduledoc """
  Hassever design-system primitives: badges, buttons, cards, toggles, form
  fields, save bars, etc. These are translated from the React/JSX prototype
  in the design handoff bundle.
  """

  use Phoenix.Component

  import UniversalProxyWeb.Components.Icons

  # ── Badge ─────────────────────────────────────────────────────────────
  attr(:variant, :atom,
    default: :neutral,
    values: [:neutral, :accent, :success, :warning, :danger]
  )

  attr(:dot, :boolean, default: false)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-semibold",
      "tracking-[0.02em]",
      badge_classes(@variant),
      @class
    ]}>
      <span :if={@dot} class="w-1.5 h-1.5 rounded-full bg-current"></span>
      {render_slot(@inner_block)}
    </span>
    """
  end

  defp badge_classes(:success), do: "bg-success-soft text-success"
  defp badge_classes(:warning), do: "bg-warning-soft text-warning"
  defp badge_classes(:danger), do: "bg-danger-soft text-danger"
  defp badge_classes(:accent), do: "bg-accent-soft text-accent"
  defp badge_classes(:neutral), do: "bg-sunken text-fg-2"

  # ── Button ────────────────────────────────────────────────────────────
  attr(:variant, :atom, default: :secondary, values: [:primary, :secondary, :ghost, :danger])
  attr(:size, :atom, default: :md, values: [:sm, :md])
  attr(:type, :string, default: "button")
  attr(:class, :string, default: nil)

  attr(:rest, :global,
    include: ~w(disabled phx-click phx-value-id phx-disable-with name value form)
  )

  slot(:inner_block)

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center gap-2 rounded-md font-medium font-sans",
        "transition-colors duration-150 ease-standard active:scale-[0.98]",
        "border focus-visible:outline-none disabled:opacity-40 disabled:pointer-events-none",
        "whitespace-nowrap",
        button_size_classes(@size),
        button_variant_classes(@variant),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  defp button_size_classes(:sm), do: "h-7 px-2.5 text-sm"
  defp button_size_classes(:md), do: "h-9 px-4 text-base"

  defp button_variant_classes(:primary),
    do: "bg-accent text-fg-on-accent border-transparent hover:bg-accent-hover"

  defp button_variant_classes(:secondary),
    do: "bg-surface text-fg-1 border-border-strong hover:bg-sunken"

  defp button_variant_classes(:ghost),
    do: "bg-transparent text-fg-1 border-transparent hover:bg-sunken"

  defp button_variant_classes(:danger),
    do: "bg-danger text-white border-transparent hover:brightness-95"

  # ── Toggle (switch) ───────────────────────────────────────────────────
  # `rest` accepts any phx-* attributes (phx-click, phx-value-*, etc.) directly.
  attr(:checked, :boolean, default: false)
  attr(:rest, :global, include: ~w(disabled))

  def toggle(assigns) do
    ~H"""
    <button
      type="button"
      role="switch"
      aria-checked={"#{@checked}"}
      class={[
        "relative w-10 h-[22px] rounded-full p-0 border-0 cursor-pointer flex-none",
        "transition-colors duration-150",
        if(@checked, do: "bg-accent", else: "bg-border-strong"),
        "after:content-[''] after:absolute after:top-0.5 after:left-0.5 after:w-[18px] after:h-[18px]",
        "after:rounded-full after:bg-white after:shadow-xs",
        "after:transition-transform after:duration-150 after:ease-standard",
        if(@checked, do: "after:translate-x-[18px]", else: "after:translate-x-0")
      ]}
      {@rest}
    >
    </button>
    """
  end

  # ── Card ──────────────────────────────────────────────────────────────
  attr(:class, :string, default: nil)
  attr(:padding, :atom, default: :p, values: [:none, :p, :lg])
  attr(:rest, :global)
  slot(:inner_block, required: true)

  def card(assigns) do
    ~H"""
    <div
      class={[
        "bg-surface border border-border-1 rounded-md shadow-sm",
        card_padding(@padding),
        @class
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp card_padding(:none), do: ""
  defp card_padding(:p), do: "p-4"
  defp card_padding(:lg), do: "p-5"

  # ── Battery pill ──────────────────────────────────────────────────────
  # A small badge showing a device's battery %, tinted by level (danger ≤15,
  # warning ≤35, neutral otherwise). Render only when a level is known
  # (`org.bluez.Battery1` is absent for devices that don't report battery).
  attr(:level, :integer, required: true)

  def battery_pill(assigns) do
    ~H"""
    <.badge variant={battery_variant(@level)} class="!text-[10px] !px-1.5 !py-px !gap-1">
      <.icon name={:battery} size={11} stroke={1.8} /> {@level}%
    </.badge>
    """
  end

  defp battery_variant(level) when is_integer(level) and level <= 15, do: :danger
  defp battery_variant(level) when is_integer(level) and level <= 35, do: :warning
  defp battery_variant(_), do: :neutral

  # ── Eyebrow (uppercase 11px label) ────────────────────────────────────
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def eyebrow(assigns) do
    ~H"""
    <div class={["text-xs font-semibold uppercase tracking-caps text-fg-3", @class]}>
      {render_slot(@inner_block)}
    </div>
    """
  end

  # ── StatLine (label + tabular readout) ────────────────────────────────
  attr(:label, :string, required: true)
  attr(:value, :string, required: true)
  attr(:tint, :string, default: nil)

  def stat_line(assigns) do
    ~H"""
    <div>
      <div class="text-[11px] font-semibold uppercase tracking-caps text-fg-3">
        {@label}
      </div>
      <div class={["text-[15px] font-semibold tabular-nums mt-0.5", if(@tint, do: "text-#{@tint}", else: "text-fg-1")]}>
        {@value}
      </div>
    </div>
    """
  end

  # ── Field (label + input wrapper) ─────────────────────────────────────
  attr(:label, :string, default: nil)
  attr(:help, :string, default: nil)
  attr(:error, :string, default: nil)
  attr(:class, :string, default: nil)
  slot(:inner_block, required: true)

  def field(assigns) do
    ~H"""
    <div class={["flex flex-col gap-1.5", @class]}>
      <label :if={@label} class="text-sm font-medium text-fg-2">{@label}</label>
      {render_slot(@inner_block)}
      <div :if={@error} class="text-xs text-danger">{@error}</div>
      <div :if={@help && !@error} class="text-xs text-fg-3">{@help}</div>
    </div>
    """
  end

  # ── Text input (.hs-input equivalent) ─────────────────────────────────
  attr(:name, :string, required: true)
  attr(:value, :string, default: "")
  attr(:type, :string, default: "text")
  attr(:placeholder, :string, default: nil)
  attr(:readonly, :boolean, default: false)
  attr(:mono, :boolean, default: false)
  attr(:class, :string, default: nil)
  attr(:rest, :global, include: ~w(id maxlength minlength autocomplete))

  def text_input(assigns) do
    ~H"""
    <input
      type={@type}
      name={@name}
      value={@value}
      placeholder={@placeholder}
      readonly={@readonly}
      class={[
        "h-9 px-3 w-full rounded-md text-base outline-none",
        "border border-border-strong bg-surface text-fg-1",
        "transition-[border-color,box-shadow] duration-150",
        "focus:border-accent focus:shadow-focus",
        "placeholder:text-fg-4",
        @mono && "font-mono",
        @readonly && "bg-sunken text-fg-2 cursor-default",
        @class
      ]}
      {@rest}
    />
    """
  end

  # ── Save bar (sticky, appears when form dirty) ────────────────────────
  attr(:dirty, :boolean, required: true)
  attr(:msg, :string, default: nil)
  attr(:save_event, :string, default: "save")
  attr(:discard_event, :string, default: "discard")

  def save_bar(assigns) do
    ~H"""
    <div :if={@dirty}
         class="sticky bottom-5 mt-6 p-3.5 rounded-md flex items-center gap-3 shadow-md
                bg-accent-soft border border-accent-soft-border text-accent">
      <.icon name={:info} size={18} stroke={2.0} />
      <div class="flex-1 text-sm text-fg-1">
        <span class="font-semibold">Unsaved changes.</span>
        <span :if={@msg} class="text-fg-2 ml-1">{@msg}</span>
      </div>
      <.button variant={:ghost} size={:sm} phx-click={@discard_event}>Discard</.button>
      <.button variant={:primary} size={:sm} phx-click={@save_event}>Save changes</.button>
    </div>
    """
  end

  # ── Modal ─────────────────────────────────────────────────────────────
  attr(:open, :boolean, required: true)
  attr(:on_close, :string, default: "modal_close")
  attr(:title, :string, required: true)
  attr(:subtitle, :string, default: nil)
  slot(:inner_block, required: true)
  slot(:footer)

  def modal(assigns) do
    ~H"""
    <div
      :if={@open}
      class="fixed inset-0 z-[100] flex items-center justify-center p-5 animate-fade"
    >
      <%!--
      Backdrop and content are siblings (not parent/child) so clicks
      inside the modal content don't bubble to the backdrop. Without
      this split we'd need event.stopPropagation() on the content,
      which would block LiveView's click delegation from reaching
      phx-click handlers on inner buttons.
      --%>
      <div phx-click={@on_close} class="absolute inset-0 bg-overlay"></div>
      <div class="relative bg-raised rounded-lg shadow-lg max-w-[520px] w-full animate-pop">
        <div class="px-6 pt-5 pb-3">
          <h3 class="text-lg font-semibold m-0 text-fg-1">{@title}</h3>
          <p :if={@subtitle} class="text-sm text-fg-2 mt-1">{@subtitle}</p>
        </div>
        <div :if={@inner_block != []} class="px-6 pb-5">{render_slot(@inner_block)}</div>
        <div
          :if={@footer != []}
          class="flex justify-end gap-2 px-6 py-4 border-t border-border-2"
        >
          {render_slot(@footer)}
        </div>
      </div>
    </div>
    """
  end
end
