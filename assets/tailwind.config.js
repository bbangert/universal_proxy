// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration

const plugin = require("tailwindcss/plugin")

module.exports = {
  // Hassever design system uses [data-theme="dark"] on <html>; tell Tailwind
  // to look for that selector instead of the default `class` strategy.
  darkMode: ["selector", '[data-theme="dark"]'],
  content: [
    "./js/**/*.js",
    "../lib/*_web.ex",
    "../lib/*_web/**/*.*ex"
  ],
  theme: {
    extend: {
      colors: {
        // Surfaces
        canvas: "var(--hs-bg-canvas)",
        surface: "var(--hs-bg-surface)",
        sunken: "var(--hs-bg-sunken)",
        raised: "var(--hs-bg-raised)",
        overlay: "var(--hs-bg-overlay)",

        // Foregrounds
        "fg-1": "var(--hs-fg-1)",
        "fg-2": "var(--hs-fg-2)",
        "fg-3": "var(--hs-fg-3)",
        "fg-4": "var(--hs-fg-4)",
        "fg-on-accent": "var(--hs-fg-on-accent)",

        // Borders
        "border-1": "var(--hs-border-1)",
        "border-2": "var(--hs-border-2)",
        "border-strong": "var(--hs-border-strong)",

        // Brand & state
        accent: "var(--hs-accent)",
        "accent-hover": "var(--hs-accent-hover)",
        "accent-soft": "var(--hs-accent-soft)",
        "accent-soft-border": "var(--hs-accent-soft-border)",
        success: "var(--hs-success)",
        "success-soft": "var(--hs-success-soft)",
        warning: "var(--hs-warning)",
        "warning-soft": "var(--hs-warning-soft)",
        danger: "var(--hs-danger)",
        "danger-soft": "var(--hs-danger-soft)",
        audio: "var(--hs-audio)",
        "audio-soft": "var(--hs-audio-soft)",

        // Port-kind tints (used in traffic stream, dot indicators, sparklines)
        zwave: "#7c4dff",
        ir: "#f0a818",
        rs232: "#e5484d",
        rs485: "#03a9f4",
        ttl: "#2fb866"
      },
      borderRadius: {
        xs: "4px",
        sm: "6px",
        md: "10px",
        lg: "14px",
        xl: "20px"
      },
      boxShadow: {
        xs: "0 1px 2px rgba(17, 24, 33, 0.04)",
        sm: "0 1px 3px rgba(17, 24, 33, 0.06), 0 1px 2px rgba(17, 24, 33, 0.04)",
        md: "0 4px 12px rgba(17, 24, 33, 0.06), 0 2px 4px rgba(17, 24, 33, 0.04)",
        lg: "0 16px 32px rgba(17, 24, 33, 0.08), 0 4px 8px rgba(17, 24, 33, 0.04)",
        focus: "0 0 0 3px rgba(3, 169, 244, 0.25)"
      },
      fontFamily: {
        sans: [
          "Inter",
          "Inter var",
          "-apple-system",
          "BlinkMacSystemFont",
          "Segoe UI Variable",
          "Segoe UI",
          "Roboto",
          "Helvetica Neue",
          "Arial",
          "Noto Sans",
          "sans-serif"
        ],
        mono: [
          "JetBrains Mono",
          "SF Mono",
          "ui-monospace",
          "Menlo",
          "Consolas",
          "Roboto Mono",
          "monospace"
        ]
      },
      fontSize: {
        // Hassever scale anchored at 14px body
        xs: ["11px", { lineHeight: "1.35" }],
        sm: ["13px", { lineHeight: "1.35" }],
        base: ["14px", { lineHeight: "1.5" }],
        md: ["16px", { lineHeight: "1.5" }],
        lg: ["18px", { lineHeight: "1.35" }],
        xl: ["22px", { lineHeight: "1.2" }],
        "2xl": ["28px", { lineHeight: "1.2" }],
        "3xl": ["34px", { lineHeight: "1.2" }],
        "4xl": ["44px", { lineHeight: "1.1" }]
      },
      letterSpacing: {
        caps: "0.08em",
        wide: "0.04em"
      },
      transitionTimingFunction: {
        standard: "cubic-bezier(0.2, 0, 0, 1)"
      }
    }
  },
  plugins: [
    plugin(({ addVariant }) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({ addVariant }) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({ addVariant }) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"]))
  ]
}
