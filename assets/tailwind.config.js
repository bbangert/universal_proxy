// See the Tailwind configuration guide for advanced usage
// https://tailwindcss.com/docs/configuration

const plugin = require("tailwindcss/plugin")
const fs = require("fs")
const path = require("path")

module.exports = {
  darkMode: "class",
  content: [
    "./js/**/*.js",
    "../lib/*_web.ex",
    "../lib/*_web/**/*.*ex"
  ],
  safelist: [
    "text-green-700", "text-green-800", "text-red-700", "text-red-800",
    "text-yellow-800", "bg-green-100", "bg-red-100", "bg-yellow-100",
    "border-green-400/40", "border-red-400/40",
    "dark:text-green-300", "dark:text-red-300", "dark:text-yellow-300",
    "dark:bg-green-900/30", "dark:bg-red-900/30", "dark:bg-yellow-900/30",
    "hover:bg-green-100", "hover:bg-red-100",
    "dark:hover:bg-green-900/20", "dark:hover:bg-red-900/20"
  ],
  theme: {
    extend: {
      colors: {
        brand: "#FD4F00",
        neon: {
          purple: "#a855f7",
          violet: "#8b5cf6",
          fuchsia: "#d946ef",
          pink: "#ec4899"
        },
        cyber: {
          bg: "#0a0a0f",
          surface: "#12121a",
          border: "#1e1e2e"
        }
      },
      boxShadow: {
        "neon-purple": "0 0 5px #a855f7, 0 0 20px #a855f7, 0 0 40px rgba(168, 85, 247, 0.3)",
        "neon-violet": "0 0 5px #8b5cf6, 0 0 20px #8b5cf6, 0 0 40px rgba(139, 92, 246, 0.3)",
        "neon-glow": "0 0 10px rgba(168, 85, 247, 0.5), inset 0 0 10px rgba(168, 85, 247, 0.05)"
      },
      fontFamily: {
        mono: ["JetBrains Mono", "Fira Code", "ui-monospace", "monospace"]
      }
    }
  },
  plugins: [
    // Allows prefixing tailwind classes with LiveView classes to add rules
    // only when LiveView classes are applied, for example:
    //
    // .phx-click-loading { ... }
    //
    plugin(({ addVariant }) => addVariant("phx-click-loading", [".phx-click-loading&", ".phx-click-loading &"])),
    plugin(({ addVariant }) => addVariant("phx-submit-loading", [".phx-submit-loading&", ".phx-submit-loading &"])),
    plugin(({ addVariant }) => addVariant("phx-change-loading", [".phx-change-loading&", ".phx-change-loading &"]))
  ]
}
