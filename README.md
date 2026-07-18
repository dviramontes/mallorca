# Mallorca

Mallorca is a native [Odin](https://odin-lang.org/) port of
[Orca](https://github.com/hundredrabbits/Orca), the esoteric livecoding
sequencer. It uses [karl2d](https://github.com/karl-zylinski/karl2d) for a
small, resizable graphical editor while keeping the simulation engine
independent from rendering and file I/O.

> [!NOTE]
> Mallorca is a work in progress and currently runs on macOS. The simulation
> sends its MIDI events out over CoreMIDI (note, control change, and pitch
> bend); OSC and UDP events are still produced but not yet delivered.

## Features

- Load, edit, and save rectangular `.orca` text grids
- Run or single-step the Orca simulation at four frames per beat
- Orca-c-compatible operators, per-cell marks, and event generation
- Live MIDI output via CoreMIDI, with tick-accurate note durations
- Network mode: host a room natively while others join and jam from a browser
- Visual highlighting for inputs, outputs, locked cells, and haste inputs
- Selection with copy/cut/paste, undo, interactive grid resize, and BPM control
- Headless core package with tests independent of the graphical application
- Bundled monospace font and example patches

The simulation follows
[Orca-c](https://github.com/hundredrabbits/Orca-c) as its semantic reference.
See [PLAN.md](PLAN.md) for architecture notes, implementation decisions, and
the project roadmap.

## Requirements

- macOS
- A recent [Odin compiler](https://odin-lang.org/docs/install/)
- [just](https://github.com/casey/just)
- Git
- [Elixir](https://elixir-lang.org/install.html) — only for network mode (the `server/` Phoenix app)

Make sure `odin` and `just` are available on your `PATH`.

## Getting started

Clone the repository, fetch the pinned karl2d dependency, and open an example:

```sh
git clone https://github.com/dviramontes/mallorca.git
cd mallorca
just setup
just run examples/a.orca
```

Run without a file to start with a blank 57×25 grid:

```sh
just run
```

When a blank grid is saved for the first time, Mallorca writes it to
`untitled.orca` in the current directory.

## Quickstart: hosting and joining a room

Mallorca has a network mode (see [PLAN.md](PLAN.md), M6): one machine runs the
native app as the **host** — it owns the clock and MIDI output and simulates
every player's grid — while other people join from a browser and live-code
together in the same room.

**1. Start the server** — a Phoenix app in [`server/`](server/) (needs Elixir):

```sh
just server-setup   # once: fetch dependencies and create the SQLite database
just server         # serves http://localhost:4000
```

**2. Host a room** — the native app, in another terminal (run `just setup`
first if you haven't):

```sh
just host           # opens the editor window and prints a room URL
just host MYROOM    # …or host a specific room code
```

The host window edits its own grid and shows a small square that is **green
when connected** to the server (red when not). It also simulates and sounds
every remote player, so keep it running and press `Space` to play.

**3. Join from a browser**

Open the room URL the host printed — e.g. `http://localhost:4000/room/MYROOM` —
pick a name, and start typing an Orca pattern. Your grid runs on the host and
plays through its MIDI output. The dashboard at `http://localhost:4000/admin`
(default `admin` / `mallorca`) shows every room's grids live.

> Network mode assumes a LAN or trusted network, and only the host machine
> emits MIDI. For a display-less host, use `just run "" --net-host --headless`.

## Controls

| Input | Action |
| --- | --- |
| Arrow keys | Move the cursor |
| `Shift` + arrow keys | Extend a rectangular selection |
| Letters, digits, and operator symbols | Write a glyph at the cursor |
| `Backspace`, `Delete`, or `.` | Clear the selection (or the current cell) |
| `Tab` | Toggle insert mode (typing advances the cursor) |
| `<` / `>` | Decrease / increase BPM |
| `Space` | Play or pause |
| `Enter` (hold) | Audition a middle-C MIDI note (checks output/synth routing) |
| `Cmd/Ctrl` + arrow keys | Grow or shrink the grid |
| `Cmd/Ctrl` + `A` | Select the whole grid |
| `Cmd/Ctrl` + `C` / `X` / `V` | Copy / cut / paste the selection |
| `Cmd/Ctrl` + `Z` | Undo the last edit |
| `Cmd/Ctrl` + `F` | Advance one simulation frame |
| `Cmd/Ctrl` + `S` | Save the grid |
| `Cmd/Ctrl` + `Q` | Quit |

Lowercase operators run when banged; hold Shift to enter their uppercase,
every-frame forms. With no active selection, copy, cut, and clear act on the
single cursor cell; with a selection they act on the whole rectangle. Paste
drops its top-left corner at the cursor, clipping anything past the grid edge.
Undo steps back through recent edits (glyph entry, clear, cut, paste, resize). The status line shows the file, grid dimensions, cursor
position, frame, BPM, playback state, and an `ins` flag while insert mode is
on. A green window border indicates that the simulation is playing.

## MIDI output

On launch Mallorca publishes a virtual CoreMIDI source named **mallorca** and,
if any hardware MIDI destination is present, also sends to the first one.
Subscribe to the virtual source from a DAW or software synth (for a purely
software setup, route it through an IAC bus in Audio MIDI Setup) to hear a
running patch. The status line shows `midi` once output is live, and `midi+dev`
when a hardware destination was also found.

Note durations are counted in VM frames, so note-offs stay aligned with the
tempo; the `%` operator is monophonic and stops any existing note on its
channel. Stopping playback or quitting flushes all sustained notes.
`examples/_midi.orca` is a good patch to try first, and holding `Enter` sends a
middle C so you can confirm your synth is wired up before running a patch.

Run with `--debug` (`just run examples/_midi.orca --debug`) to log every MIDI
message to stderr.

## Development

The `Justfile` contains the common project commands:

```sh
just check       # type-check the application and core packages
just test        # run simulation and field tests
just build       # create a debug binary at bin/mallorca
just release     # create an optimized binary
just clean       # remove build artifacts
```

You can also pass a patch to the run recipe:

```sh
just run examples/j.orca
```

## Project structure

```text
assets/          bundled font
examples/        example .orca grids
patches/         local patches applied to the pinned karl2d revision
src/core/        grid, marks, events, and simulation engine
src/main.odin    window, editor, clock, rendering, and file I/O
src/net.odin     network host: connects to the server, simulates players
server/          Phoenix server for network mode (rooms, admin, LiveView)
Justfile         setup, build, test, and run commands
PLAN.md          architecture and roadmap
```

The core package deliberately has no rendering, timing, MIDI, or filesystem
dependencies. The host application owns those concerns and invokes the core
once per simulation tick.

## Acknowledgements

Mallorca is based on the design and behavior of
[Hundred Rabbits' Orca](https://github.com/hundredrabbits/Orca) and especially
its [C port](https://github.com/hundredrabbits/Orca-c). Rendering and platform
integration are provided by [karl2d](https://github.com/karl-zylinski/karl2d).
