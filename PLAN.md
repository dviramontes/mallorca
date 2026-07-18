# mallorca — a native Odin port of Orca

A native port of [Orca](https://github.com/hundredrabbits/Orca), the esoteric
livecoding sequencer, written in [Odin](https://odin-lang.org/) with
[karl2d](https://github.com/karl-zylinski/karl2d) for rendering.

The port leverages the design of the C port
([hundredrabbits/Orca-c](https://github.com/hundredrabbits/Orca-c)), which
cleanly separates the simulation VM from all I/O — that separation is the
backbone of this plan. Orca-c (not the JS version) is the semantic reference
throughout; they differ in small details.

## Reference architecture (orca-c)

```diagram
╭──────────────╮     ╭───────────────────────────╮
│  tui_main.c  │     │  sim.c                    │
│  (ncurses UI,│────▶│  orca_run(gbuffer, mbuffer│
│  clock, MIDI)│     │   h, w, tick, events, seed)│
╰──────────────╯     ╰────────────┬──────────────╯
                                  │ no IO, no MIDI, no clock
                     ╭────────────┴──────────────╮
                     │ field.c  grid of Glyphs   │
                     │ mbuffer  per-cell Marks    │
                     │ oevent_list  MIDI/OSC evts │
                     ╰───────────────────────────╯
```

Key facts that shape the port:

- The **grid** ("field") is a flat `[]u8` buffer of glyphs with width/height.
  `.` is empty. Files on disk (`.orca`) are rectangular text grids; the file
  determines the dimensions, and non-rectangular files are rejected.
- Each tick, `orca_run` scans the grid top-left to bottom-right, evaluating
  operators. Uppercase letters run every frame, lowercase on `*bang*`.
- A parallel **mark buffer** holds per-cell flags (locked, sleep,
  haste-input, input, output). It is *per-tick scratch output*: cleared at
  the start of every tick, written during the scan (lock/sleep suppress later
  evaluation within that same tick), and read by the UI for highlighting.
  Marks are never persistent simulation input.
- Operators that produce sound emit **events** (MIDI note, MIDI CC, MIDI
  pitch bend, OSC int list, UDP string) into an event list. The host decides
  what to do with them — which is exactly why we can defer MIDI: we collect
  events and drop them until M5.

## Architecture of mallorca

Two Odin packages, mirroring the orca-c split:

```
mallorca/
├── Justfile
├── PLAN.md
├── karl2d/            # vendored karl2d (via `just setup`, pinned commit)
├── examples/          # .orca example files (copied from orca-c)
├── assets/            # bundled monospace font
└── src/
    ├── core/          # package core — no rendering, timing, MIDI, or files
    │   ├── field.odin     # grid buffer; parse/serialize .orca *bytes*
    │   ├── marks.odin     # per-cell flag buffer (per-tick scratch)
    │   ├── sim.odin       # operator evaluation, orca_run equivalent
    │   ├── events.odin    # full Event union (all 5 orca-c variants)
    │   └── sim_test.odin  # golden-fixture conformance tests
    └── main.odin      # package main — karl2d window, input, draw, clock,
                       #   file load/save (owns all filesystem access)
```

Core design decisions:

- **`core` has no rendering, timing, MIDI, or filesystem access.** Field
  load/save operate on byte slices (`parse_field(bytes)` /
  `serialize_field(grid)`); `main` owns file I/O. This keeps core testable
  headlessly (like orca-c's `cli` binary) and open to a future TUI or web
  build.
- **The tick API mutates the grid and overwrites marks/events:**

  ```odin
  // Mutates grid; clears and rewrites marks and events for this tick.
  run_tick :: proc(grid: ^Grid, tick, seed: u64,
                   marks: ^Marks, events: ^[dynamic]Event)
  ```

  For fresh highlighting while paused (after load/edit), a preview path runs
  a tick against a scratch copy of the grid, keeps the marks, and discards
  the scratch grid and events — same as orca-c.
- **Glyphs are `u8`**, same as orca-c. The charset is ASCII only.
- **Grid dimensions come from the loaded file** (exact allocation); a fixed
  default (orca-c's) is used only when no file is given. Interactive resize
  is a separate M4 feature.
- **Rendering** draws the grid as monospaced text with karl2d, one glyph per
  fixed-size cell rectangle, colored by mark/state: dim for empty `.`,
  bright for operators, inverted cell for the cursor, highlight for
  locked/output cells. Ruler `+` markers every 8 cells are a rendering
  overlay only — never written into the field. A monospace font is bundled
  from M1 (karl2d's default font is Roboto, which is proportional).
- **Imports:** unprefixed Odin imports are relative to the importing file,
  so `src/main.odin` uses `import k2 "../karl2d"` and `import "core"`.

## Milestones

Each milestone is runnable end to end.

### M1 — Window + grid display  ← first goal
- Vendor karl2d (`just setup` clones and pins it in `karl2d/`).
- Open a window, draw a W×H grid of glyphs with row/col ruler markers every
  8 cells, using a bundled monospace font at fixed cell positions.
- Draw a status bar (grid size, frame count placeholder, BPM placeholder).
- Load an `.orca` file passed as an argument (dimensions from the file,
  rectangular-or-reject) and display its glyphs; empty default grid
  otherwise.
- Deliverable: `just run examples/<file>.orca` shows the file's grid.

### M2 — Cursor + editing
- Arrow keys move the cursor; typing `0-9 a-z A-Z * # : ; = ! ? %` etc.
  inserts a glyph; backspace/delete clears; Ctrl+S saves back to the file.
- Selection is out of scope for now (single-cell cursor only).

### M3 — Simulation (no sound delivery)
- Port `sim.c` faithfully: mark buffer, port reading/locking/sleep, all
  operators — `A-Z`, lowercase-on-bang, `*` bang, `#` comment, and the I/O
  operators `!` (MIDI CC), `%` (mono note), `:` (note), `;` (UDP),
  `=` (OSC), `?` (pitch bend). All five event variants and their full
  payloads (channel, octave, note, velocity, duration, mono flag, …) are
  produced and tested, even though delivery is disabled.
- Timing: **four VM frames per beat** — `frame_seconds = 60 / BPM / 4`
  (orca-c's rule), default 120 BPM. One host timing function is the single
  source of truth (shared later with M5 note scheduling). Lag advances one
  tick when crossing the deadline (accumulated elapsed time, orca-c style),
  not tick-from-wall-clock.
- Space toggles play/pause; Ctrl+F single-steps one frame while paused.
- Conformance tests: golden fixtures compare `(grid, marks, ordered events)`
  after *each tick*, generated from a small pinned orca-c harness. Coverage:
  every operator, banged/unbanged lowercase, writes ahead/behind the scan
  position, lock and sleep interactions, grid boundaries, deterministic `R`
  with fixed tick/seed, all five event variants.

### M4 — Livecoding polish
- BPM adjust keys, frame counter, interactive grid resize, copy/paste,
  insert/append modes as needed.
- Copy/cut/paste additionally mirror through the macOS system pasteboard, so a
  block copied in mallorca can be pasted into other apps and an Orca pattern
  copied from anywhere pastes into the grid (see `src/clipboard.odin`). Undo
  (`Cmd/Ctrl+Z`) is a full grid+cursor snapshot stack.

### M5 — MIDI out (explicitly later)
- CoreMIDI on macOS, consuming the event list M3 already produces. This is
  a stateful host-side scheduler, not a pass-through:
  - consume ordered per-tick events;
  - maintain a sustained-note list with deadline-based note-offs computed
    from duration and the shared timing function;
  - implement `%` channel monophony (stop existing notes on that channel);
  - flush all active notes on pause/stop/device change/shutdown;
  - select and retain a CoreMIDI destination;
  - MIDI clock (24 PPQN), if added, is a separate feature from VM events.

### M6 — Server + remote play (host-authoritative)  ← current

The native mallorca is the **only** native client and the single **host**: it
owns the MIDI rig, the clock, and — the pivotal decision — the Orca VM for
*every* participant. All other players are **remote browsers** live-coding Orca
in a Phoenix LiveView editor; they never run a native VM. As with every prior
milestone, `core` is untouched — this is a host concern in `main.odin` plus a
new server.

**M6 does not depend on M7.** M6 concerns grid *state*, transport, and a new
`net.odin`; M7 (modal editing) only reshapes the native `handle_input` path.
They touch disjoint regions of `main.odin` and can be sequenced either way.

**Who runs the VM (the load-bearing decision).** Remote players are browsers, so
they cannot run the Odin VM. Rather than reimplement the sim in Elixir (a second
VM to keep conformant with `core`) or embed `core` as a NIF, the **host
simulates every player's grid** — one VM instance per participant, all on the
host's single clock. The consequences are mostly *simplifying*:
- **No cross-machine clock sync, and no timed events on the wire.** Remote
  players send *edits* (untimed, latency-tolerant); the host derives all MIDI
  from grid state on its own clock. The look-ahead / Ableton-Link machinery an
  earlier draft of this milestone needed simply disappears — a late edit lands a
  tick later, which is exactly how livecoding already behaves.
- **MIDI never crosses the network** — it is produced and consumed entirely on
  the host (the M5 CoreMIDI scheduler, unchanged in spirit).
- The **server is a pure relay + UI + presence**; it does not run Orca.

Alternative kept on file: expose `core` as a C-ABI shared library and drive it
from Elixir (NIF/port) so the *server* simulates. Feasible because `core` is
pure and I/O-free, but it splits the clock across machines and reintroduces the
timing problem — worth revisiting only if the host's per-player CPU cost ever
mattered (it won't, for a handful of small grids).

```diagram
                                          browser player B ─┐
   ╭───────────────────────────╮   ╭──────────────────────┴─╮
   │ HOST — native mallorca     │   │ Phoenix server         │◀─ browser player C
   │ • VM per player (its own + │◀─▶│ • LiveView Orca editor │
   │   one per remote player)   │   │ • presence / relay     │
   │ • clock master             │   │ • admin dashboard      │
   │ • CoreMIDI → sound         │   │   (no Orca VM)          │
   ╰───────────────────────────╯   ╰────────────────────────╯
       edits ▲          ▼ evaluated grid + marks
```

**The remote edit loop** (per remote player):
1. Player types in the LiveView editor → an edit (glyph/cursor/clear) → server →
   host.
2. Host applies the edit to that player's grid. The host is the **single
   writer**: the VM also mutates the grid every tick, so remote edits and VM
   writes must serialize on the host (apply edits between ticks) to avoid races.
3. Host ticks every grid on its clock, producing events → emits MIDI → sound.
4. Host streams the evaluated grid + marks back → server → that player's
   LiveView, which renders the running pattern (bangs, playhead, locks).

The browser shows the host's authoritative grid with **optimistic local echo**
of the last keystroke so typing feels instant; the host's next snapshot
reconciles it.

**LiveView Orca editor component.**
- Renders a grid of glyphs with cursor, ruler markers, and mark highlighting —
  the browser twin of mallorca's renderer.
- Captures keystrokes (glyph entry, arrow/cursor movement, backspace/clear) and
  ships edits; transport keys (play/pause, BPM) route to the host as requests.
- ~8 fps state refresh (4 frames/beat @ 120 BPM) is trivial bandwidth for the
  small grids in play, well within a channel's budget.
- Modal editing (M7) is a *native*-client affordance; the browser editor starts
  with plain glyph entry, revisited only if remote players want it.

**Server / admin (Phoenix LiveView).**
- Room join by code + display name; live presence list.
- Transport controls (play/pause/BPM) as requests to the host, which owns tempo.
- Per-player live grid view (read-only "code streaming") on the dashboard.
- Monitoring: edit rate, round-trip latency, connected players; auth on admin.

**Native host (`src/net.odin`, new).** Connects to the server as the host,
registers its grids, receives remote edits and transport requests, streams
evaluated grids back, and surfaces the room roster in the status bar.
Platform-guarded like `midi.odin`.

**Failure handling.**
- Remote player disconnect → host drops that player's grid and flushes its
  sustained notes; dashboard marks them gone.
- Host disconnect → everything goes silent (the host is the only sound source);
  players keep editing against a stalled clock until it returns.
- Server restart → players rejoin by room code; the host re-registers its grids.

**Deliberately deferred / out of scope.**
- Players seeing each other's grids/cursors → **M8**.
- Server-side or browser-side VM — the host simulates everything.
- Additional native peers — there is exactly one native client (the host).
- Shared single grid + CRDT — each participant has a private grid.
- Recording/playback; internet-scale / NAT traversal (assume LAN or trusted VPN).

**Repo / toolchain.** A new `server/` Phoenix app (LiveView), scaffolded with
`mix phx.new server`, built via `mix` and run by a `just server` recipe; the
native side gains `src/net.odin`. The BEAM toolchain lives alongside Odin — the
two build independently.

**Open questions.**
1. Edit/VM write serialization: apply remote edits only between ticks (simplest)
   vs. a locked queue drained each frame.
2. Optimistic-echo reconciliation when the VM overwrites a cell the player just
   typed (distinguish player-input cells from operator-output cells).
3. Transport authority: host-owned tempo only, or may the dashboard drive it?
4. Grid streaming: whole-grid snapshots on change (start here) vs. deltas.

**Deliverable:** a remote browser player joins by room code, live-codes an Orca
pattern in the LiveView editor, and hears it played by the native host in sync
with the host's own grid; the dashboard shows every grid live.

### M7 — Modal (vim-style) editing

A deliberate departure from Orca: layer a modal, vim-inspired editing model
over the grid. Orca's native model is "the keyboard always types glyphs"; vim's
Normal mode reuses the letter keys as commands, so the two cannot coexist in
one mode. Nearly every vim motion/operator letter (`h j k l w b d y p r`) is
also a valid Orca operator, which forces the separation. M7 resolves this with
explicit modes and adopts only the vim idioms that map cleanly onto a
fixed-size glyph grid.

**Guiding rule ("only where it makes sense").** The grid is fixed-size ASCII:
no variable-length lines to insert/remove, no real "words". We take vim's
*modes, motions, and operators*, but redefine or drop anything whose vim
meaning assumes a growable text buffer. Orca-central keys keep working in every
mode: `Space` (play/pause), the `Cmd/Ctrl` chords (save, step, resize,
clipboard, undo), the arrow keys (movement), and `Enter` (audition tone).

**Modes.** `Esc` is the pivot the user asked for: it leaves per-cell glyph
entry (Insert) and returns to whole-grid, multi-line navigation (Normal).

| Mode | Purpose | Enter | Leave |
| --- | --- | --- | --- |
| Insert | Type a glyph, then advance the cursor east (text-like) | `i` `a` `I` `A` (from Normal); launch default | `Esc` → Normal |
| Normal | Navigate the whole grid; keys are motions/commands | `Esc` (from Insert/Visual) | `i` `a` `v` … |
| Visual | Rectangular block select (reuses the M4 selection) | `v` (from Normal) | `Esc`, or an operator (`y` `d` `c`) |

Launching in **Insert** preserves mallorca's out-of-box feel — typing operators
"just works" — and makes the vim layer opt-in the moment you press `Esc`. The
status bar shows `-- INSERT --` / `-- NORMAL --` / `-- VISUAL --` in place of
today's `ins` flag.

**Motions** (Normal + Visual; optional count prefix, e.g. `5j`):
- `h j k l` — left/down/up/right (arrows still work everywhere)
- `0` / `$` — first / last column of the row
- `^` — first non-empty cell in the row
- `w` / `b` — next / previous non-empty cell in the row (grid-redefined "word")
- `gg` / `G` — top / bottom row, same column
- a leading `{count}` repeats the next motion

**Normal-mode edits:**
- `x` — clear the cell under the cursor
- `r{glyph}` — replace one cell with the next glyph typed, stay in Normal
- `d{motion}` / `c{motion}` — clear a span (and, for `c`, enter Insert);
  `dd` / `cc` act on the whole row (clear to `.`, since rows can't be removed)
- `y{motion}` / `yy` — yank a span / the row to the clipboard
- `p` / `P` — paste the clipboard at / before the cursor (reuses the system
  pasteboard path from M4)
- `u` — undo (shares the M4 stack); `Ctrl+R` / `Cmd+Shift+Z` — redo (adds a
  redo stack)
- `.` — repeat last edit (stretch goal; may defer)

**Visual mode:** `v` toggles a rectangular block anchored at the cursor;
motions extend it; `y` yank, `d`/`x` delete, `c` change (delete → Insert),
`p` paste-over; `Esc` cancels.

**Deliberately skipped or redefined** (the "where it makes sense" cuts):
- `o`/`O` (open line), `J` (join), true `dd` row removal — the grid is
  fixed-size, so there are no lines to add/remove; `dd`/`cc` clear the row.
- `w`/`b` word semantics → redefined as non-empty-run jumps within a row.
- Ex commands (`:`), search (`/`), multiple registers, macros — out of scope;
  `:` and `/` stay Orca glyphs, never a command line.
- `Space` stays play/pause (not a rightward motion) — an intentional
  Orca-over-vim override.

**Implementation notes:**
- Add an `Edit_Mode` enum (`.Insert` `.Normal` `.Visual`) plus small pending
  state (count digits, pending operator `d`/`c`/`y`, pending `g`, pending `r`)
  to `App`; fold today's `insert_mode` bool into it.
- Dispatch by mode near the top of `handle_input`: Insert keeps the current
  glyph-entry path; Normal/Visual consume letters/digits as commands. The
  `Cmd/Ctrl` chords, arrows, `Space`, and `Enter` are handled *before* the
  mode branch so they work in every mode.
- Motions resolve to a target cell; operators apply over the inclusive
  rectangle between origin and target, reusing `selection_rect`, `clear_cell`,
  `copy_selection`, and `paste_*`.
- Redo needs a redo stack that `push_undo` clears on a fresh edit (standard);
  this extends the M4 undo stack.
- The whole layer lives in `main.odin` (a host concern); `core` is untouched.

**Deliverable:** `Esc` toggles Normal/Insert; `hjkl` + counts navigate;
`x`/`dd`/`yy`/`p` and `v`+`y` edit; the status bar shows the mode; and classic
glyph typing still works out of the box on launch.

**Resolved decisions:**
1. Insert semantics: **type-and-advance** — writing a glyph moves the cursor
   east (text-like); `r{glyph}` in Normal is the in-place single replace.
2. Launch mode: **Insert** — classic typing works out of the box; `Esc` opens
   the vim layer.
3. Redo: **both** `Ctrl+R` (vim) and `Cmd+Shift+Z` (mac).

### M8 — Player awareness & shared cursors

Builds on M6's relay so players *see each other perform*, not just the host. M8
depends on M6 but not the reverse, and is independently demoable — which is why
it is its own milestone: it keeps M6's go/no-go question (does remote
live-coding sound in time through the host?) uncluttered by the social layer.

**Grid broadcast.** Each player's evaluated grid streams to every other player
in the room (opt-in per room), so everyone watches everyone's pattern run — the
shared-jam view, not just the admin dashboard's.

**Shared cursors.** Every player's cursor position (and selection, later)
broadcasts through Phoenix Presence and renders as a labeled, per-player-colored
remote cursor — in each LiveView editor *and* in the native host's view.

**Presence-rich UI.** Playing vs. spectating, per-player activity/status,
join/leave notifications.

**Deliberately deferred.**
- Real-time collaborative editing of a *single shared* grid (still N private
  grids).
- Voice/chat and spectator replay.

**Deliverable:** two remote players plus the host each edit their own grid and
see the others' grids and cursors live in the LiveView, all sounding through the
host.

## Justfile commands

- `just setup` — clone karl2d into `karl2d/`, pinned to a known commit
- `just run [file]` — debug build & run
- `just build` / `just release` — build binaries into `bin/`
- `just test` — run core package tests
- `just check` — `odin check` both packages independently
- `just clean` — remove build artifacts

## Open questions / assumptions

- karl2d over raylib: chosen per project brief; karl2d is beta but covers
  everything we need (window, text, input).
- Vendoring by pinned clone (not git submodule) to keep the repo simple.
- Font: any OFL-licensed monospace face works; pick one in M1 and bundle it
  under `assets/`.
