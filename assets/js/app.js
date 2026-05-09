import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"

// Sync the theme button's visible glyph to whatever <html data-theme=…> says.
function applyThemeIcon() {
  const stored = localStorage.getItem("up-theme") || "auto"
  document.querySelectorAll("#theme-toggle [data-icon]").forEach(el => {
    el.classList.toggle("hidden", el.dataset.icon !== stored)
  })
}

function applyTheme() {
  const stored = localStorage.getItem("up-theme") || "auto"
  let effective = stored
  if (stored === "auto") {
    effective = window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
  }
  document.documentElement.setAttribute("data-theme", effective)
  applyThemeIcon()
}

const Hooks = {
  ThemeToggle: {
    mounted() {
      applyTheme()
      this.el.addEventListener("click", () => {
        const cur = localStorage.getItem("up-theme") || "auto"
        const next = cur === "auto" ? "light" : cur === "light" ? "dark" : "auto"
        localStorage.setItem("up-theme", next)
        applyTheme()
      })
      // React to OS theme changes when in auto mode.
      window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", applyTheme)
    },
    updated() { applyThemeIcon() }
  },

  // Auto-scrolls a streaming container to the bottom on every render.
  // Mounted by the Traffic tab's `phx-hook="AutoScroll"` only when the
  // user has the Autoscroll checkbox on; toggling it off re-renders
  // without the hook attribute, which unmounts this hook.
  AutoScroll: {
    mounted() { this.scrollToBottom() },
    updated() { this.scrollToBottom() },
    scrollToBottom() {
      this.el.scrollTop = this.el.scrollHeight
    }
  }
}

// Server-side `push_event("copy", %{text: "..."})` ends up here as a
// browser event named "phx:copy". Used by Security tab's encryption-key
// Copy button.
window.addEventListener("phx:copy", event => {
  const text = event.detail && event.detail.text
  if (text && navigator.clipboard) {
    navigator.clipboard.writeText(text).catch(err => {
      console.warn("Clipboard copy failed:", err)
    })
  }
})

let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
let liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: false,
  hooks: Hooks,
  params: {_csrf_token: csrfToken}
})

topbar.config({barColors: {0: "#03a9f4"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

liveSocket.connect()
window.liveSocket = liveSocket
