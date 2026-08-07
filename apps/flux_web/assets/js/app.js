// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/flux_web"
import topbar from "../vendor/topbar"

// ── Voice input ────────────────────────────────────────────────────────
// Push-to-talk: hold the mic button, release to stop; the recording
// uploads through LiveView's file upload and comes back transcribed via
// a "voice-transcript" push event that fills the chat input.
const MicRecorder = {
  mounted() {
    this.recorder = null
    this.chunks = []

    const start = async e => {
      e.preventDefault()
      if (this.recorder) return
      try {
        const stream = await navigator.mediaDevices.getUserMedia({audio: true})
        this.chunks = []
        this.recorder = new MediaRecorder(stream)
        this.recorder.addEventListener("dataavailable", ev => this.chunks.push(ev.data))
        this.recorder.addEventListener("stop", () => {
          stream.getTracks().forEach(track => track.stop())
          const blob = new Blob(this.chunks, {type: this.recorder.mimeType || "audio/webm"})
          this.recorder = null
          if (blob.size < 1000) return // accidental tap
          const file = new File([blob], "voice-note.webm", {type: blob.type})
          this.upload(this.el.dataset.uploadName || "audio", [file])
        })
        this.recorder.start()
        this.el.classList.add("btn-error")
      } catch (_err) {
        this.recorder = null
      }
    }
    const stop = () => {
      if (!this.recorder) return
      this.el.classList.remove("btn-error")
      this.recorder.stop()
    }

    this.el.addEventListener("pointerdown", start)
    this.el.addEventListener("pointerup", stop)
    this.el.addEventListener("pointerleave", stop)

    this.handleEvent("voice-transcript", ({text}) => {
      const input = document.getElementById("chat-content-input")
      if (input && text) {
        input.value = (input.value ? input.value + " " : "") + text.trim()
        input.focus()
      }
    })
  },
}

// Read a reply aloud with the browser's own voices — no provider needed.
window.addEventListener("click", e => {
  const button = e.target.closest && e.target.closest(".speak-reply")
  if (!button) return
  const bubble = button.closest(".chat")
  const content = bubble && bubble.querySelector(".markdown-chat, .chat-bubble")
  if (!content || !window.speechSynthesis) return
  if (speechSynthesis.speaking) { speechSynthesis.cancel(); return }
  speechSynthesis.speak(new SpeechSynthesisUtterance(content.innerText.trim()))
})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, MicRecorder},
})

// ── Themed confirm ─────────────────────────────────────────────────────
// Replaces the native window.confirm for every [data-confirm] click with
// a DaisyUI <dialog>. Capture phase runs before phoenix_html's and
// LiveView's own handlers; on OK the attribute is lifted for one
// synchronous re-click so neither library re-confirms. (Native confirm
// also freezes browser automation — see the batch-11 QA notes.)
function themedConfirm(message) {
  return new Promise(resolve => {
    const dialog = document.createElement("dialog")
    dialog.className = "modal"
    dialog.innerHTML = `
      <div class="modal-box max-w-sm">
        <h3 class="font-semibold text-base mb-2">Are you sure?</h3>
        <p class="text-sm opacity-80 whitespace-pre-wrap" data-confirm-message></p>
        <div class="modal-action">
          <button type="button" class="btn btn-sm" data-cancel>Cancel</button>
          <button type="button" class="btn btn-sm btn-error" data-ok>Confirm</button>
        </div>
      </div>`
    dialog.querySelector("[data-confirm-message]").textContent = message
    document.body.appendChild(dialog)
    const done = ok => { dialog.close(); dialog.remove(); resolve(ok) }
    dialog.querySelector("[data-ok]").addEventListener("click", () => done(true))
    dialog.querySelector("[data-cancel]").addEventListener("click", () => done(false))
    dialog.addEventListener("cancel", e => { e.preventDefault(); done(false) })
    dialog.addEventListener("click", e => { if (e.target === dialog) done(false) })
    dialog.showModal()
    dialog.querySelector("[data-ok]").focus()
  })
}

window.addEventListener("click", e => {
  const el = e.target.closest && e.target.closest("[data-confirm]")
  if (!el) return
  e.preventDefault()
  e.stopImmediatePropagation()
  const message = el.getAttribute("data-confirm")
  themedConfirm(message).then(ok => {
    if (!ok) return
    el.removeAttribute("data-confirm")
    el.click()
    el.setAttribute("data-confirm", message)
  })
}, true)

// ── Copy buttons on chat replies ───────────────────────────────────────
// Delegated: any .copy-reply button copies its bubble's rendered text.
window.addEventListener("click", e => {
  const button = e.target.closest && e.target.closest(".copy-reply")
  if (!button) return
  const bubble = button.closest(".chat")
  const content = bubble && bubble.querySelector(".markdown-chat, .chat-bubble")
  if (!content) return
  navigator.clipboard.writeText(content.innerText.trim()).then(() => {
    const original = button.innerHTML
    button.innerHTML = "Copied!"
    setTimeout(() => { button.innerHTML = original }, 1200)
  })
})

// ── Command palette (Ctrl/Cmd+K) ───────────────────────────────────────
// Fetches /console/palette once per open and filters client-side.
// Pure JS + one JSON endpoint, so every console page gets it for free.
const paletteKindBadge = {
  page: "→", flux: "⚡", app: "💬", dataset: "📚", labeling: "🏷", template: "📄"
}

function openPalette() {
  if (document.getElementById("command-palette")) return

  const dialog = document.createElement("dialog")
  dialog.id = "command-palette"
  dialog.className = "modal items-start pt-24"
  dialog.innerHTML = `
    <div class="modal-box max-w-lg p-0">
      <input type="text" placeholder="Jump to a page, flux, app, dataset…"
        class="input input-bordered w-full rounded-b-none focus:outline-none"
        aria-label="Command palette search" />
      <ul class="menu w-full max-h-80 overflow-y-auto flex-nowrap p-1"></ul>
    </div>`
  document.body.appendChild(dialog)

  const input = dialog.querySelector("input")
  const list = dialog.querySelector("ul")
  let entries = []
  let matches = []
  let selected = 0

  const close = () => { dialog.close(); dialog.remove() }

  const go = entry => {
    if (!entry) return
    close()
    if (entry.kind === "workspace") {
      // Workspace switching is a POST — build a CSRF'd form on the fly.
      const form = document.createElement("form")
      form.method = "POST"
      form.action = entry.url
      const token = document.createElement("input")
      token.type = "hidden"
      token.name = "_csrf_token"
      token.value = document.querySelector("meta[name='csrf-token']").getAttribute("content")
      form.appendChild(token)
      document.body.appendChild(form)
      form.submit()
    } else {
      window.location.href = entry.url
    }
  }

  const renderList = () => {
    const query = input.value.trim().toLowerCase()
    matches = entries
      .filter(e => e.label.toLowerCase().includes(query))
      .sort((a, b) => {
        const aStarts = a.label.toLowerCase().startsWith(query) ? 0 : 1
        const bStarts = b.label.toLowerCase().startsWith(query) ? 0 : 1
        return aStarts - bStarts || a.label.localeCompare(b.label)
      })
      .slice(0, 12)
    selected = Math.min(selected, Math.max(matches.length - 1, 0))
    list.innerHTML = ""
    matches.forEach((entry, i) => {
      const li = document.createElement("li")
      const a = document.createElement("a")
      a.className = i === selected ? "active" : ""
      a.innerHTML = `<span class="w-5 text-center">${paletteKindBadge[entry.kind] || "•"}</span>`
      a.appendChild(document.createTextNode(entry.label))
      const kind = document.createElement("span")
      kind.className = "ml-auto badge badge-ghost badge-xs"
      kind.textContent = entry.kind
      a.appendChild(kind)
      a.addEventListener("mousedown", e => { e.preventDefault(); go(entry) })
      li.appendChild(a)
      list.appendChild(li)
    })
    if (matches.length === 0) {
      list.innerHTML = `<li class="p-3 text-sm opacity-60">Nothing matches.</li>`
    }
  }

  input.addEventListener("input", () => { selected = 0; renderList() })
  input.addEventListener("keydown", e => {
    if (e.key === "ArrowDown") { e.preventDefault(); selected = Math.min(selected + 1, matches.length - 1); renderList() }
    else if (e.key === "ArrowUp") { e.preventDefault(); selected = Math.max(selected - 1, 0); renderList() }
    else if (e.key === "Enter") { e.preventDefault(); go(matches[selected]) }
  })
  dialog.addEventListener("cancel", e => { e.preventDefault(); close() })
  dialog.addEventListener("click", e => { if (e.target === dialog) close() })

  dialog.showModal()
  input.focus()

  // No accept header: the :browser pipeline only negotiates html, and
  // the controller answers JSON regardless.
  fetch("/console/palette")
    .then(resp => resp.json())
    .then(data => { entries = data.entries || []; renderList() })
    .catch(() => { list.innerHTML = `<li class="p-3 text-sm opacity-60">Could not load.</li>` })
}

window.addEventListener("keydown", e => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
    e.preventDefault()
    openPalette()
  }
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

