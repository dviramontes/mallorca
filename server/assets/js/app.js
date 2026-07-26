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
import {hooks as colocatedHooks} from "phoenix-colocated/mallorca_server"
import topbar from "../vendor/topbar"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")

// Capture clipboard paste and forward the text to the LiveView (multi-line
// Orca blocks). Single-character typing still goes through phx-window-keydown.
// M10 operator names for the hover readout — the JS twin of `operator_name`
// in src/main.odin. Lowercase operators are bang-triggered; non-operators have
// no name.
const OP_NAMES = {
  A: "add", B: "subtract", C: "clock", D: "delay",
  E: "move east", F: "if", G: "generator", H: "halt",
  I: "increment", J: "jump", K: "konkat", L: "lesser",
  M: "multiply", N: "move north", O: "offset (read)", P: "push",
  Q: "query", R: "random", S: "move south", T: "track",
  U: "euclid", V: "variable", W: "move west", X: "teleport",
  Y: "yump", Z: "lerp",
  "*": "bang", "#": "comment", ":": "midi (note)", "%": "midi (mono)",
  "!": "midi cc", "?": "pitch bend", ";": "udp", "=": "osc",
}

function operatorName(ch) {
  if (!ch) return ""
  const lower = ch.length === 1 && ch >= "a" && ch <= "z"
  const name = OP_NAMES[lower ? ch.toUpperCase() : ch] || ""
  if (!name || !lower) return name
  return name === "offset (read)" ? "offset (read, bang)" : `${name} (bang)`
}

const Hooks = {
  Paste: {
    mounted() {
      this.handler = (e) => {
        const text = (e.clipboardData || window.clipboardData).getData("text")
        if (text) {
          e.preventDefault()
          this.pushEvent("paste", {text})
        }
      }
      window.addEventListener("paste", this.handler)
    },
    destroyed() {
      window.removeEventListener("paste", this.handler)
    },
  },

  // Hover readout (M10): show the hovered operator's full name in the corner
  // readout element. Purely client-side (delegated listeners, no round-trip);
  // falls back to the keyboard cursor and survives grid re-renders since the
  // listeners live on the container.
  OpReadout: {
    mounted() {
      this.out = document.getElementById("op-readout")
      this.showCursor = () => {
        const cursor = this.el.querySelector("[data-edit-cursor]")
        if (this.out) this.out.textContent = operatorName(cursor?.dataset.glyph)
      }
      this.showActive = () => {
        const hovered = this.el.querySelector("[data-glyph]:hover")
        if (hovered && this.out) {
          this.out.textContent = operatorName(hovered.dataset.glyph)
        } else {
          this.showCursor()
        }
      }
      this.over = (e) => {
        const cell = e.target.closest("[data-glyph]")
        if (!cell || !this.el.contains(cell)) return
        if (this.out) this.out.textContent = operatorName(cell.dataset.glyph)
      }
      this.out_ = (e) => {
        const nextCell = e.relatedTarget?.closest?.("[data-glyph]")
        if (!nextCell || !this.el.contains(nextCell)) this.showCursor()
      }
      this.el.addEventListener("mouseover", this.over)
      this.el.addEventListener("mouseout", this.out_)
      this.showActive()
    },
    updated() {
      this.showActive()
    },
    destroyed() {
      this.el.removeEventListener("mouseover", this.over)
      this.el.removeEventListener("mouseout", this.out_)
      if (this.out) this.out.textContent = ""
    },
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
  // Surface modifier keys so Cmd/Ctrl chords (paste, copy) don't type a glyph.
  metadata: {
    keydown: (e) => ({metaKey: e.metaKey, ctrlKey: e.ctrlKey}),
  },
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
