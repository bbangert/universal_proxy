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
  },

  // Copy the element's `data-clipboard` attr to the system clipboard on
  // click. Used by the Audio tab's per-card "more" disclosure for the
  // client_id. Briefly mutates the button's text to give the user a
  // visible "Copied" cue without round-tripping through the server.
  CopyToClipboard: {
    mounted() {
      this.el.addEventListener("click", () => {
        const text = this.el.dataset.clipboard
        if (!text || !navigator.clipboard) return
        navigator.clipboard.writeText(text).then(() => {
          const original = this.el.textContent
          this.el.textContent = "Copied"
          setTimeout(() => { this.el.textContent = original }, 1200)
        }).catch(err => console.warn("Clipboard copy failed:", err))
      })
    }
  },

  // Focus + select-all on mount, with a small delay so the modal
  // mount transition doesn't steal the caret. Used by the Audio rename
  // modal's text input.
  AutofocusSelect: {
    mounted() {
      setTimeout(() => {
        this.el.focus()
        if (typeof this.el.select === "function") this.el.select()
      }, 30)
    }
  },

  // Auto-dismisses a flash message after `data-timeout` ms by replaying
  // a click on the element itself, which reuses the existing
  // phx-click="lv:clear-flash" binding — same path the user gets by
  // clicking the flash manually. Hovering pauses the timer so a message
  // being read doesn't vanish underneath the cursor.
  AutoDismissFlash: {
    mounted() {
      this.startTimer()
      this.el.addEventListener("mouseenter", () => this.clearTimer())
      this.el.addEventListener("mouseleave", () => this.startTimer())
    },
    destroyed() { this.clearTimer() },
    startTimer() {
      const timeout = parseInt(this.el.dataset.timeout, 10) || 4000
      this.clearTimer()
      this.timer = setTimeout(() => this.el.click(), timeout)
    },
    clearTimer() {
      if (this.timer) clearTimeout(this.timer)
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

// Traffic tab's Export button: server pushes the formatted log; we
// stuff it into a Blob and trigger a same-page download.
window.addEventListener("phx:traffic-export", event => {
  const detail = event.detail || {}
  const content = detail.content || ""
  const filename = detail.filename || "traffic.log"
  const blob = new Blob([content], {type: "text/plain;charset=utf-8"})
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
})

// Server-side `push_event("download", %{content, filename})` triggers a
// same-page file download. Used by the Security tab's "Download key" button
// to save the device's SSH private key.
window.addEventListener("phx:download", event => {
  const detail = event.detail || {}
  const content = detail.content || ""
  const filename = detail.filename || "download"
  const blob = new Blob([content], {type: "application/octet-stream"})
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = filename
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
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
