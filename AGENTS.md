# AGENTS.md

This file provides guidance to Claude Code (claude.ai/code) and other coding
agents when working with code in this repository.

Mallorca is a native [Odin](https://odin-lang.org/) port of
[Orca](https://github.com/hundredrabbits/Orca), the livecoding sequencer.
[Orca-c](https://github.com/hundredrabbits/Orca-c) (not the JS version) is the
semantic reference for all VM behavior.

## Setup (required before first build)

karl2d and fofoca are vendored dependencies, neither committed (`karl2d/` and
`fofoca/` are both gitignored). You **must** run `just setup` before any
build/check/run, or imports fail and the staticlib has no manifest to build
from:

```sh
just setup   # clones both at their pinned commits, applies patches/ to karl2d
```

The pins are `karl2d_rev` and `fofoca_rev` in the `Justfile`; karl2d also gets
`patches/karl2d-mac-modifier-keys.patch` on top. Update either deliberately.
Re-running `setup` is safe: it re-checks-out both and skips the karl2d patch
when it is already applied.

Both land on a **detached HEAD**, on purpose. The Justfile claims an exact
commit for each, and a checkout sitting on a branch could be moved by a stray
`git pull` while the pin still said otherwise. Detaching makes the pin true.
Treat `karl2d/` and `fofoca/` as disposable build inputs — `just setup`
re-derives them at any time — and do not commit in either.

`fofoca/` is a gitignored clone of
[fofoca-network/fofoca](https://github.com/fofoca-network/fofoca), the Rust
cargo workspace behind the p2p mesh FFI (see
[docs/p2p-protocol.md](docs/p2p-protocol.md)). To change the engine, work in
your own clone of that repo on a branch, push there, then bump `fofoca_rev`
here and re-run `just setup`. For a quick iteration you can edit `fofoca/`
in place and run `just check` to rebuild the staticlib and relink Odin against
it, but nothing there survives the next `setup` unless you have pushed it. Its
`rust-toolchain.toml` pins the toolchain (rustup installs it automatically on
first `cargo` invocation inside that directory); building it requires rustup
and network access to fetch its patched `iroh`/`iroh-gossip` git dependencies
on a cold machine. `just fofoca` builds it and copies the staticlib to
`fofoca/lib/`; every `check`/`run`/`build`/`release`/`bundle`/`test`
recipe depends on `fofoca`, so this is normally automatic (a no-op ~0.2s once
built). It dominates the build: it is 96.7% of the release binary, and it is
linked whether or not a room is ever opened. `just measure` quantifies that and
the runtime cost — see [docs/ffi-cost.md](docs/ffi-cost.md), and `just profile`
for a build with the timing instrumentation compiled in.
[mesh-slimming.md](https://github.com/fofoca-network/fofoca/blob/main/docs/mesh-slimming.md)
root-causes those numbers and drove the crate split; it moved to the fofoca
repo with the engine.

Mallorca has two independent multiplayer transports, chosen at launch and
never both in one session:

- **Serverless mesh** (`--create-room` / `--join-room`) — native peers stream
  snapshots to each other over fofoca. See below and
  [docs/p2p-protocol.md](docs/p2p-protocol.md).
- **Phoenix relay** (`--net-host`, needs `just server`) — the Elixir app in
  `server/` accepts a host over TCP on :4001 and serves browser players at
  `http://localhost:4000/room/MYROOM`, plus an admin dashboard at `/admin`.
  See [docs/m6-network-protocol.md](docs/m6-network-protocol.md).

They differ in more than transport: the relay runs a VM per remote player on
the host and replays their edits, while the mesh treats peers as snapshot
replicas that are never ticked locally. `src/net.odin` is the relay client;
`src/p2p/` is the mesh. Only the small `Remote_View` projection in
`main.odin` is shared between them.

## Commands

```sh
just check              # odin check both packages (src and src/core) independently
just test               # run core package tests (odin test src/core)
just run [file]         # debug build & run, optionally loading an .orca file
just create-room [file] # run and open a new p2p room
just join-room <hash> [file]  # run and join an existing p2p room
just build              # debug binary -> bin/mallorca, wrapped in bin/Mallorca.app
just release            # optimized binary (-o:speed) -> bin/mallorca
just bundle             # optimized, ad-hoc signed bin/Mallorca.app
just clean               # remove bin/
```

The three launch recipes run `bin/Mallorca.app/Contents/MacOS/mallorca`, not the
bare binary: macOS reads the Dock/Finder icon and the app name from the bundle's
`Info.plist`, so an unbundled executable gets a placeholder icon and the name
"mallorca". Exec'ing the binary inside the bundle rather than `open`ing the app
keeps stdout, argv and the working directory, so relative `.orca` paths still
resolve. `build` and `bundle` write the same `bin/Mallorca.app` — whichever ran
last decides whether the bundled binary is the debug or the optimized one.

Two macOS details the recipes handle, both easy to reintroduce:

- Every build passes `-minimum-os-version:11.0.0` (`min_os` in the `Justfile`).
  Odin 2026-07a otherwise stamps `LC_BUILD_VERSION minos 28.0` — one past the
  installed SDK, and past the running system — and LaunchServices then refuses
  the bundle with error `-10825`, drawing a prohibitory badge over the icon.
  The flag makes `ld` warn that some `libfofoca_ffi.a` objects (blake3's and
  sha2's `cc`-compiled asm) were built for 27.0 — expected, and not worth
  pinning `MACOSX_DEPLOYMENT_TARGET` for: those crates ignore it.
- `just bundle` re-signs with `codesign --force --sign -`. The linker's ad-hoc
  signature is made before the bundle exists, so it leaves `Info.plist=not bound`
  and `Sealed Resources=none`.

`src/icon.odin` additionally embeds `assets/mallorca.icns` and sets it as the
Dock tile at startup, which is what a bare `bin/mallorca` (outside the bundle)
relies on.

`just icon` regenerates `assets/icon/mallorca.iconset/` and
`assets/mallorca.icns` from the CoreGraphics scene in
`assets/icon/render_icon.swift` (`assets/icon/island.svg` describes the same
scene, but nothing rasterizes it — there is no SVG rasterizer on the build
machine). The scene is drawn in a 1024 space and `makeImage` places it on
Apple's grid: a body covering 824 of the 1024 canvas, a drop shadow at 256px and
up, and the corner from `squirclePath` rather than a circular arc. Those numbers
come from tracing the alpha edge of Terminal's, Notes' and Finder's icns, which
are identical to the pixel: the corner fits a superellipse with a box of 0.3013
of the body and an exponent of 2.85 to within 1.1px rms, where the documented
circular radius of 185.4 is 3x worse. Getting the grid wrong is visible — a
full-bleed icon, which is what this repo shipped until `just icon` existed,
stands ~24% larger than every neighbour in the Dock.

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

- **`src/p2p/` (package `p2p`)** — serverless rooms: the room state machine,
  the mesh worker thread that owns every FFI call, and jam compose. Knows
  nothing about `App` — `roster_tick` returns a `Roster_Result` the host
  applies (`apply_roster` in `main.odin`), which is what lets `main` import it.
  - `fofoca_ffi.odin` is the raw C binding, mirroring
    `fofoca/crates/fofoca-ffi/include/fofoca.h`. Its entry points keep the
    header's bare names (`open`, `recv`, `send`) via `@(link_name)`, which is
    why the room opener is `p2p.start` rather than `p2p.open`.

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
diagram, and the milestone roadmap (M1–M5). All milestones are implemented: the
VM's MIDI events are delivered over CoreMIDI (`src/midi.odin`, macOS-only), with
the tick-driven note scheduler in `main.odin`. OSC (`=`) and UDP (`;`) events are
still produced by the VM but not yet delivered.
