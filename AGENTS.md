# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) and other coding
agents when working with code in this repository.

Mallorca is a native [Odin](https://odin-lang.org/) port of
[Orca](https://github.com/hundredrabbits/Orca), the livecoding sequencer.
[Orca-c](https://github.com/hundredrabbits/Orca-c) (not the JS version) is the
semantic reference for all VM behavior.

## Setup (required before first build)

karl2d is a vendored dependency, not committed (`karl2d/` is gitignored). You
**must** run `just setup` before any build/check/run, or imports fail:

```sh
just setup   # clones karl2d, checks out the pinned commit, applies patches/
```

`setup` pins a specific karl2d revision (see `karl2d_rev` in the `Justfile`) and
applies `patches/karl2d-mac-modifier-keys.patch` on top. Update the pin
deliberately; re-running `setup` re-checks-out and re-applies the patch.

## Commands

```sh
just check       # odin check both packages (src and src/core) independently
just test        # run core package tests (odin test src/core)
just run [file]  # debug build & run, optionally loading an .orca file
just build       # debug binary -> bin/mallorca
just release     # optimized binary (-o:speed) -> bin/mallorca
just clean       # remove bin/
```

Run a single core test by name:

```sh
odin test src/core -define:ODIN_TEST_NAMES=core.test_midi_note_numbers
```

**Every `odin` invocation for the `src` package must pass
`-define:KARL2D_AUDIO_BACKEND=nil`** (the `Justfile` recipes already do). The
CoreAudio backend is unused and leaks memory in AudioToolbox internals while
idle; MIDI in M5 will use CoreMIDI directly, not this backend.

Currently macOS-only: `src/main.odin` imports `core:sys/darwin/Foundation`.
Guard platform code with `#+build` when porting to other OSes.

## Architecture

Two Odin packages mirror orca-c's clean split between the simulation VM and all
I/O. This separation is the backbone of the project — preserve it.

- **`src/core/` (package `core`)** — the VM. Has **no** rendering, timing,
  MIDI, or filesystem access, which keeps it testable headlessly.
  - `field.odin` — `Grid` (flat `[]u8` of glyphs, `.` is empty). `parse_field`
    / `serialize_field` operate on **byte slices**, never files; dimensions
    come from the parsed data and non-rectangular input is rejected.
  - `marks.odin` — `Mark` bit_set per cell. This buffer is **per-tick scratch
    output**: cleared at the start of every tick, written during the scan
    (lock/sleep suppress later evaluation within the same tick), read by the UI
    for highlighting. Never persistent simulation input.
  - `events.odin` — the `Event` union (5 orca-c variants: MIDI note, MIDI CC,
    MIDI pitch bend, OSC ints, UDP string). The VM only *produces* these; the
    host decides delivery. Delivery is deferred to M5, so events are currently
    discarded.
  - `sim.odin` — the VM. `run_tick` scans the grid top-left to bottom-right;
    uppercase operators run every frame, lowercase only on a neighboring `*`
    bang. One big `switch` in `run_tick` dispatches each glyph to its `op_*`
    proc.

- **`src/main.odin` (package `main`)** — the host. Owns the karl2d window,
  input, rendering, the clock, and **all** file I/O. The `App` struct holds all
  application state; `main` reads a file into a byte slice and calls
  `core.parse_field`.

### The tick contract

```odin
// Mutates grid; clears and rewrites marks and events for this tick.
run_tick :: proc(grid: Grid, marks: []Mark, tick, seed: uint, events: ^[dynamic]Event)
```

`run_tick` mutates the grid in place and fully overwrites marks and events each
call. For fresh highlighting while paused (after a load or edit),
`preview_marks` runs a tick against a *scratch copy* of the grid, keeps the
marks, and discards the scratch grid and events — same trick as orca-c's TUI.
The host calls this only when `app.dirty` and not `playing`.

### Timing

Four VM frames per beat: `frame_seconds = 60 / BPM / 4` (orca-c's rule,
default 120 BPM). `frame_seconds` in `main.odin` is the single source of truth —
M5 note scheduling must reuse it. The host accumulates elapsed time and advances
whole ticks when crossing deadlines (capped by `MAX_TICKS_PER_FRAME`); it does
not derive ticks from the wall clock.

### Conventions

- Glyphs are `u8`, ASCII only — same as orca-c. Many bit tricks in `sim.odin`
  (case folding, note numbers) are ported verbatim from `sim.c`.
- Unprefixed Odin imports are relative to the importing file's directory, so
  `main.odin` uses `import k2 "../karl2d"` and `import orca "core"`.
- Ruler `+` markers (every 8 cells) are a rendering overlay only — never
  written into the field.

See [PLAN.md](PLAN.md) for the full architecture rationale, the orca-c reference
diagram, and the milestone roadmap (M1–M5). M3 (simulation) is the current
state; M4 (livecoding polish) and M5 (CoreMIDI out) are not yet implemented.
