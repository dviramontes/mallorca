# Mallorca

Mallorca is a native [Odin](https://odin-lang.org/) port of
[Orca](https://github.com/hundredrabbits/Orca), the esoteric livecoding
sequencer. It uses [karl2d](https://github.com/karl-zylinski/karl2d) for a
small, resizable graphical editor while keeping the simulation engine
independent from rendering and file I/O.

> [!NOTE]
> Mallorca is a work in progress and currently runs on macOS. The simulation
> produces Orca's MIDI, OSC, and UDP events, but the application does not yet
> deliver them to external devices or services, so it is currently silent.

## Features

- Load, edit, and save rectangular `.orca` text grids
- Run or single-step the Orca simulation at four frames per beat
- Orca-c-compatible operators, per-cell marks, and event generation
- Visual highlighting for inputs, outputs, locked cells, and haste inputs
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

## Controls

| Input | Action |
| --- | --- |
| Arrow keys | Move the cursor |
| `Shift` + arrow keys | Extend a rectangular selection |
| Letters, digits, and operator symbols | Write a glyph at the cursor |
| `Backspace`, `Delete`, or `.` | Clear the current cell |
| `Tab` | Toggle insert mode (typing advances the cursor) |
| `<` / `>` | Decrease / increase BPM |
| `Space` | Play or pause |
| `Cmd/Ctrl` + arrow keys | Grow or shrink the grid |
| `Cmd/Ctrl` + `A` | Select the whole grid |
| `Cmd/Ctrl` + `C` / `X` / `V` | Copy / cut / paste the selection |
| `Cmd/Ctrl` + `F` | Advance one simulation frame |
| `Cmd/Ctrl` + `S` | Save the grid |
| `Cmd/Ctrl` + `Q` | Quit |

Lowercase operators run when banged; hold Shift to enter their uppercase,
every-frame forms. With no active selection, copy and cut act on the single
cursor cell. Paste drops its top-left corner at the cursor, clipping anything
past the grid edge. The status line shows the file, grid dimensions, cursor
position, frame, BPM, playback state, and an `ins` flag while insert mode is
on. A green window border indicates that the simulation is playing.

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
