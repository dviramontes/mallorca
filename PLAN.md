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
