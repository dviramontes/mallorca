// mallorca — native Odin port of Orca.
// Grid display + editing + running simulation, with the VM's MIDI events
// delivered via CoreMIDI (see midi.odin). OSC and UDP remain deferred.
package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import NS "core:sys/darwin/Foundation" // macOS-only for now; gate with #+build when porting
import k2 "../karl2d"
import orca "core"

FONT_DATA :: #load("../assets/JetBrainsMono-Regular.ttf")

// Font size used only to compute the initial window dimensions; after
// that, the grid scales to fill the window width.
INITIAL_FONT_SIZE :: 32

// Play-state border: a solid frame inset from the window edges; green
// while playing, absent while paused.
BORDER_INSET :: 10
BORDER_THICKNESS :: 3

// Content inset from window edges; leaves room for the border.
MARGIN :: 24

// JetBrains Mono has an advance of exactly 0.6 em; 1.15 em line height
// keeps the glyphs filling most of the cell.
ADVANCE_EM :: 0.6
LINE_EM :: 1.15

RULER_SPACING :: 8

// Cursor blink: shown for this many seconds, then hidden for the same, so a
// full cycle is 2×. ~0.53s matches the common editor blink rate.
BLINK_INTERVAL :: 0.53

// The status line renders at this fraction of the grid glyph size — it's
// heads-up/debug text, secondary to the grid.
STATUS_SCALE :: 0.6

// Orca-ish theme.
BG :: k2.Color{0x17, 0x17, 0x17, 0xff}
FG :: k2.Color{0xf0, 0xf0, 0xf0, 0xff}
DIM :: k2.Color{0x50, 0x50, 0x50, 0xff}
RULER :: k2.Color{0x88, 0x88, 0x88, 0xff}
STATUS :: k2.Color{0xb0, 0xb0, 0xb0, 0xff}
CURSOR_BG :: k2.Color{0xff, 0xff, 0xff, 0xff}
CURSOR_FG :: k2.Color{0x17, 0x17, 0x17, 0xff}

// Mark highlighting (per-tick sim scratch, see core/marks.odin).
OUTPUT_BG :: k2.Color{0xf0, 0xf0, 0xf0, 0xff} // freshly written cells, inverted
OUTPUT_FG :: k2.Color{0x17, 0x17, 0x17, 0xff}
INPUT :: k2.Color{0x6b, 0xd9, 0xd9, 0xff} // cyan-ish: operand cells
HASTE :: k2.Color{0x3f, 0x9d, 0x9d, 0xff} // darker cyan: hasted operands
LOCKED :: k2.Color{0x70, 0x70, 0x70, 0xff} // comment/data cells

PLAY_BORDER :: k2.Color{0x5d, 0xd0, 0x5d, 0xff} // green frame while playing
SELECT :: k2.Color{0x2c, 0x3e, 0x63, 0xff} // muted blue behind selected cells

DEFAULT_W :: 57
DEFAULT_H :: 25

DEFAULT_FILE_NAME :: "untitled.orca"

DEFAULT_BPM :: 120
BPM_MIN :: 10
BPM_MAX :: 300

App :: struct {
	grid:         orca.Grid,
	file_name:    string,
	cursor_x:     int,
	cursor_y:     int,
	status_msg:   string, // transient message shown in the status bar
	status_timer: f32,
	repeat:       [len(REPEAT_KEYS)]f32,
	insert_mode:  bool, // typing advances the cursor when true
	audition:     bool, // Enter held: sounding the middle-C audition tone
	debug:        bool, // --debug: log edit/selection/clipboard activity

	// Cursor blink: `blink` accumulates seconds and toggles visibility every
	// BLINK_INTERVAL; movement resets it so the cursor is always shown while
	// you're navigating or typing.
	blink:        f32,
	blink_x:      int,
	blink_y:      int,

	// Rectangular selection: anchored at (sel_x, sel_y), extended to the
	// cursor. Inactive selections are treated as the single cursor cell.
	sel_active:   bool,
	sel_x:        int,
	sel_y:        int,

	// Clipboard: a rectangular block of glyphs (heap-owned).
	clip_cells:   []u8,
	clip_w:       int,
	clip_h:       int,

	// Undo history: full grid + cursor snapshots, pushed before each edit.
	undo:         [dynamic]Undo_Snapshot,

	// Simulation state.
	marks:        []orca.Mark,
	events:       [dynamic]orca.Event, // produced each tick, dispatched to MIDI
	tick:         uint,
	bpm:          int,
	playing:      bool,
	accum:        f32, // elapsed seconds not yet consumed by ticks
	dirty:        bool, // grid edited while paused; marks need a preview

	// MIDI output (M5).
	midi:         Midi,
	sus:          [dynamic]Sus_Note, // notes awaiting their note-off
}

// A grid + cursor snapshot for undo. Owns its own copy of the cells.
Undo_Snapshot :: struct {
	cells:    []u8,
	width:    int,
	height:   int,
	cursor_x: int,
	cursor_y: int,
}

// Cap on retained undo steps; oldest are dropped past this.
UNDO_MAX :: 128

// A note-on awaiting its note-off, counted down in VM frames (the note's
// duration). Tick-driven, matching orca-c, so tempo changes stay in sync.
Sus_Note :: struct {
	channel: u8,
	note:    u8, // final MIDI note number, 0-127
	frames:  int,
}

// Four VM frames per beat — orca-c's timing rule. The single source of
// truth for tick length (M5 note scheduling must reuse this).
frame_seconds :: proc(bpm: int) -> f32 {
	return 60.0 / f32(bpm) / 4.0
}

main :: proc() {
	app: App

	// Args: an optional .orca file path and an optional --debug flag, in any
	// order. The first non-flag argument is the file.
	debug := false
	for arg in os.args[1:] {
		if arg == "--debug" {
			debug = true
		} else if arg != "" && app.file_name == "" {
			app.file_name = arg
		}
	}

	if app.file_name != "" {
		data, read_err := os.read_entire_file_from_path(app.file_name, context.allocator)
		if read_err != nil {
			fmt.eprintfln("mallorca: cannot read %q: %v", app.file_name, read_err)
			os.exit(1)
		}
		g, err := orca.parse_field(data)
		delete(data)
		if err != .None {
			fmt.eprintfln("mallorca: failed to load %q: %v", app.file_name, err)
			os.exit(1)
		}
		app.grid = g
	} else {
		app.grid = orca.make_grid(DEFAULT_W, DEFAULT_H)
	}
	app.debug = debug
	app.marks = orca.make_marks(app.grid)
	app.bpm = DEFAULT_BPM
	app.dirty = true // preview marks for the freshly loaded grid
	app.midi = midi_init(debug)
	defer orca.destroy_grid(&app.grid)
	defer delete(app.marks)
	defer delete(app.events)
	defer delete(app.clip_cells)
	defer delete(app.sus)
	defer clear_undo(&app)
	defer midi_shutdown(&app.midi)
	defer if app.status_msg != "" {
		delete(app.status_msg)
	}

	window_w := MARGIN*2 + app.grid.width*(INITIAL_FONT_SIZE * 3 / 5)
	window_h := MARGIN*2 + app.grid.height*(INITIAL_FONT_SIZE * 23 / 20) + INITIAL_FONT_SIZE + MARGIN
	k2.init(window_w, window_h, "mallorca", {window_mode = .Windowed_Resizable})
	defer k2.shutdown()

	// Dynamic font: bakes glyphs on demand, so it stays sharp at any
	// window-derived size.
	font := k2.load_dynamic_font_from_bytes(FONT_DATA)
	defer k2.destroy_font(font)

	for {
		// Drain autoreleased AppKit/GL objects every frame. Neither karl2d
		// nor a non-bundle executable sets up a per-frame pool, so without
		// this, memory grows unboundedly while idle.
		pool := NS.AutoreleasePool.alloc()->init()

		quit := !k2.update() || (ctrl_held() && k2.key_went_down(.Q))
		if !quit {
			handle_input(&app)
			update_sim(&app)
			update_blink(&app)
			tick_status(&app)

			layout := compute_layout(app.grid)
			k2.clear(BG)
			draw_border(&app)
			draw_selection(&app, layout)
			draw_grid(app.grid, app.marks, font, layout)
			draw_cursor(&app, font, layout)
			draw_status(&app, font, layout)
			k2.present()

			free_all(context.temp_allocator)
		}

		pool->drain()
		if quit {
			flush_notes(&app) // silence any sustained notes before exit
			break
		}
	}
}

//-------//
// INPUT //
//-------//

REPEAT_KEYS :: [?]k2.Keyboard_Key{.Left, .Right, .Up, .Down, .Backspace}
REPEAT_DELAY :: 0.35
REPEAT_RATE :: 0.05

ctrl_held :: proc() -> bool {
	// Accept Cmd on macOS as well as Ctrl.
	return(
		k2.key_is_held(.Left_Control) ||
		k2.key_is_held(.Right_Control) ||
		k2.key_is_held(.Left_Super) ||
		k2.key_is_held(.Right_Super) \
	)
}

shift_held :: proc() -> bool {
	return k2.key_is_held(.Left_Shift) || k2.key_is_held(.Right_Shift)
}

// Fires on key press, then repeats while held. `slot` indexes REPEAT_KEYS.
key_repeats :: proc(app: ^App, slot: int, key: k2.Keyboard_Key) -> bool {
	if k2.key_went_down(key) {
		app.repeat[slot] = 0
		return true
	}
	if !k2.key_is_held(key) {
		app.repeat[slot] = 0
		return false
	}
	app.repeat[slot] += k2.get_frame_time()
	if app.repeat[slot] > REPEAT_DELAY {
		app.repeat[slot] -= REPEAT_RATE
		return true
	}
	return false
}

// Shifted glyphs for non-letter keys on a US layout, covering Orca's
// I/O operators: ! (CC), # (comment), % (mono), * (bang), : (note),
// ? (pitch bend); plus ; (UDP) and = (OSC) unshifted.
Glyph_Key :: struct {
	key:     k2.Keyboard_Key,
	base:    u8, // 0 = no glyph without shift
	shifted: u8, // 0 = no glyph with shift
}

GLYPH_KEYS :: [?]Glyph_Key{
	{.N0, '0', 0},
	{.N1, '1', '!'},
	{.N2, '2', 0},
	{.N3, '3', '#'},
	{.N4, '4', '$'},
	{.N5, '5', '%'},
	{.N6, '6', 0},
	{.N7, '7', 0},
	{.N8, '8', '*'},
	{.N9, '9', 0},
	{.Semicolon, ';', ':'},
	{.Equal, '=', 0},
	{.Slash, 0, '?'},
	{.NP_Multiply, '*', '*'},
}

handle_input :: proc(app: ^App) {
	// Audition tone: hold Enter to sound middle C (MIDI note 60) on channel
	// 0, whether playing or not — a quick way to check the MIDI output and
	// synth routing. The play border lights while it sounds.
	AUDITION_NOTE :: u8(60)
	held := k2.key_is_held(.Enter)
	if held && !app.audition {
		midi_note_on(&app.midi, 0, AUDITION_NOTE, 100)
		app.audition = true
	} else if !held && app.audition {
		midi_note_off(&app.midi, 0, AUDITION_NOTE)
		app.audition = false
	}

	// Ctrl/Cmd shortcuts own the whole key event: save, step, resize,
	// clipboard, select-all. Handled first so those keys never leak into
	// movement or glyph entry.
	if ctrl_held() {
		handle_shortcuts(app)
		return
	}

	shift := shift_held()

	// Cursor movement (with key repeat). Shift extends the selection;
	// an unshifted move collapses it.
	mdx, mdy := 0, 0
	if key_repeats(app, 0, .Left) {mdx -= 1}
	if key_repeats(app, 1, .Right) {mdx += 1}
	if key_repeats(app, 2, .Up) {mdy -= 1}
	if key_repeats(app, 3, .Down) {mdy += 1}
	if mdx != 0 || mdy != 0 {
		if shift {
			begin_selection(app)
		} else {
			app.sel_active = false
		}
		app.cursor_x = clamp(app.cursor_x + mdx, 0, app.grid.width - 1)
		app.cursor_y = clamp(app.cursor_y + mdy, 0, app.grid.height - 1)
	}

	// BPM adjust: '<' / '>' (Shift+Comma / Shift+Period).
	if shift {
		if k2.key_went_down(.Comma) {adjust_bpm(app, -1)}
		if k2.key_went_down(.Period) {adjust_bpm(app, +1)}
	}

	// Insert-mode toggle.
	if k2.key_went_down(.Tab) {
		app.insert_mode = !app.insert_mode
		set_status(app, fmt.aprintf("insert %s", "on" if app.insert_mode else "off"))
	}

	// Clearing. Backspace deletes the previous cell in insert mode
	// (typewriter-style); Delete and '.' always clear in place. Shifted
	// '.' is the BPM key above, not a clear.
	if key_repeats(app, 4, .Backspace) {
		if app.insert_mode {
			app.cursor_x = max(app.cursor_x - 1, 0)
		}
		clear_cell(app)
	}
	if k2.key_went_down(.Delete) || (k2.key_went_down(.Period) && !shift) {
		clear_cell(app)
	}

	// Play/pause.
	if k2.key_went_down(.Space) {
		app.playing = !app.playing
		app.accum = 0
		if !app.playing {
			flush_notes(app) // don't leave notes hanging when stopping
		}
		set_status(app, fmt.aprintf("%s", "playing" if app.playing else "paused"))
	}

	// Letters: unshifted lowercase (on-bang ops), shifted uppercase
	// (every-frame ops). Keyboard_Key values match ASCII uppercase.
	for key in k2.Keyboard_Key.A ..= k2.Keyboard_Key.Z {
		if k2.key_went_down(key) {
			glyph := u8(key)
			if !shift {
				glyph += 'a' - 'A'
			}
			put_glyph(app, glyph)
		}
	}

	// Digits and symbols.
	for gk in GLYPH_KEYS {
		if k2.key_went_down(gk.key) {
			glyph := gk.shifted if shift else gk.base
			if glyph != 0 {
				put_glyph(app, glyph)
			}
		}
	}
}

// Ctrl/Cmd chords. Ctrl+arrows resize the grid; the rest are single keys.
handle_shortcuts :: proc(app: ^App) {
	if k2.key_went_down(.Left) {resize_grid_by(app, -1, 0)}
	if k2.key_went_down(.Right) {resize_grid_by(app, +1, 0)}
	if k2.key_went_down(.Up) {resize_grid_by(app, 0, -1)}
	if k2.key_went_down(.Down) {resize_grid_by(app, 0, +1)}
	if k2.key_went_down(.S) {save(app)}
	if k2.key_went_down(.F) {
		// Single-step one frame (orca-c's Ctrl+F). Release the previous
		// step's notes first so a manually stepped note never hangs past
		// the next step regardless of its programmed duration.
		flush_notes(app)
		step_tick(app)
	}
	if k2.key_went_down(.C) {copy_selection(app)}
	if k2.key_went_down(.X) {cut_selection(app)}
	if k2.key_went_down(.V) {paste_clip(app)}
	if k2.key_went_down(.A) {select_all(app)}
	if k2.key_went_down(.Z) {undo(app)}
}

// Write a glyph at the cursor, collapsing any selection. In insert mode
// the cursor then advances east (stopping at the right edge).
put_glyph :: proc(app: ^App, glyph: u8) {
	push_undo(app)
	orca.grid_set(app.grid, app.cursor_x, app.cursor_y, glyph)
	app.sel_active = false
	app.dirty = true
	if app.insert_mode {
		app.cursor_x = min(app.cursor_x + 1, app.grid.width - 1)
	}
}

// Clear the active selection if there is one, otherwise the single cursor
// cell. (Backspace/Delete/'.' all route here.)
clear_cell :: proc(app: ^App) {
	push_undo(app)
	x0, y0, x1, y1 := selection_rect(app)
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			orca.grid_set(app.grid, x, y, orca.EMPTY_GLYPH)
		}
	}
	app.dirty = true
}

adjust_bpm :: proc(app: ^App, d: int) {
	app.bpm = clamp(app.bpm + d, BPM_MIN, BPM_MAX)
	set_status(app, fmt.aprintf("%d bpm", app.bpm))
}

//-----------//
// SELECTION //
//-----------//

// Start a selection anchored at the cursor if one isn't already active.
begin_selection :: proc(app: ^App) {
	if !app.sel_active {
		app.sel_active = true
		app.sel_x = app.cursor_x
		app.sel_y = app.cursor_y
		if app.debug {
			fmt.eprintfln("select: anchor at (%d,%d)", app.sel_x, app.sel_y)
		}
	}
}

// The selected rectangle in grid coordinates. An inactive selection is the
// single cursor cell, so copy/cut always have something to act on.
selection_rect :: proc(app: ^App) -> (x0, y0, x1, y1: int) {
	if !app.sel_active {
		return app.cursor_x, app.cursor_y, app.cursor_x, app.cursor_y
	}
	return min(app.sel_x, app.cursor_x), min(app.sel_y, app.cursor_y),
		max(app.sel_x, app.cursor_x), max(app.sel_y, app.cursor_y)
}

select_all :: proc(app: ^App) {
	app.sel_active = true
	app.sel_x, app.sel_y = 0, 0
	app.cursor_x = app.grid.width - 1
	app.cursor_y = app.grid.height - 1
}

copy_selection :: proc(app: ^App) {
	x0, y0, x1, y1 := selection_rect(app)
	w, h := x1 - x0 + 1, y1 - y0 + 1
	delete(app.clip_cells)
	app.clip_cells = make([]u8, w*h)
	app.clip_w, app.clip_h = w, h
	for y in 0 ..< h {
		for x in 0 ..< w {
			app.clip_cells[y*w + x] = orca.grid_get(app.grid, x0 + x, y0 + y)
		}
	}
	// Mirror the block to the system pasteboard (rows joined by '\n') so it can
	// be pasted into other apps, and so our own paste — which prefers the
	// system clipboard — round-trips an in-app copy faithfully.
	system_clipboard_write(clip_to_text(app, context.temp_allocator))
	if app.debug {
		fmt.eprintfln(
			"copy: sel_active=%v rect=(%d,%d)-(%d,%d) -> %dx%d %q",
			app.sel_active, x0, y0, x1, y1, w, h, string(app.clip_cells),
		)
	}
	set_status(app, fmt.aprintf("copied %dx%d", w, h))
}

cut_selection :: proc(app: ^App) {
	copy_selection(app)
	push_undo(app)
	x0, y0, x1, y1 := selection_rect(app)
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			orca.grid_set(app.grid, x, y, orca.EMPTY_GLYPH)
		}
	}
	app.sel_active = false
	app.dirty = true
	set_status(app, fmt.aprintf("cut %dx%d", app.clip_w, app.clip_h))
}

// Serialize the internal clipboard block to text, rows joined by '\n'.
clip_to_text :: proc(app: ^App, allocator := context.allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)
	for y in 0 ..< app.clip_h {
		if y > 0 {
			strings.write_byte(&b, '\n')
		}
		strings.write_bytes(&b, app.clip_cells[y*app.clip_w:y*app.clip_w + app.clip_w])
	}
	return strings.to_string(b)
}

// Paste at the cursor. Prefers the system pasteboard so a pattern copied from
// anywhere drops into the grid; falls back to the internal block clipboard
// when the pasteboard has no usable text.
paste_clip :: proc(app: ^App) {
	if text, ok := system_clipboard_read(context.temp_allocator); ok {
		if app.debug {
			fmt.eprintfln("paste: system clipboard %q at cursor=(%d,%d)", text, app.cursor_x, app.cursor_y)
		}
		paste_text(app, text)
		return
	}
	if app.debug {
		fmt.eprintfln(
			"paste: internal clip=%dx%d at cursor=(%d,%d) %q",
			app.clip_w, app.clip_h, app.cursor_x, app.cursor_y, string(app.clip_cells),
		)
	}
	if app.clip_w == 0 {
		set_status(app, fmt.aprintf("nothing to paste"))
		return
	}
	push_undo(app)
	for y in 0 ..< app.clip_h {
		for x in 0 ..< app.clip_w {
			orca.grid_set(app.grid, app.cursor_x + x, app.cursor_y + y, app.clip_cells[y*app.clip_w + x])
		}
	}
	app.sel_active = false // drop the highlight so the paste is visible
	app.dirty = true
	set_status(app, fmt.aprintf("pasted %dx%d", app.clip_w, app.clip_h))
}

// Paste free-form text at the cursor: '\n' starts a new row (back at the
// cursor column), '\r' is ignored, non-printable bytes become empty cells.
// Cells past the grid edge are dropped (grid_set clips).
paste_text :: proc(app: ^App, text: string) {
	push_undo(app)
	x, y := app.cursor_x, app.cursor_y
	lines := 1
	for c in transmute([]u8)text {
		switch c {
		case '\n':
			y += 1
			x = app.cursor_x
			lines += 1
		case '\r':
		// ignored
		case:
			glyph := c if c >= '!' && c <= '~' else orca.EMPTY_GLYPH
			orca.grid_set(app.grid, x, y, glyph)
			x += 1
		}
	}
	app.sel_active = false
	app.dirty = true
	set_status(app, fmt.aprintf("pasted %d line%s", lines, "" if lines == 1 else "s"))
}

// Reallocate the grid (and mark buffer), preserving the overlapping
// top-left content and clamping the cursor into the new bounds.
resize_grid_by :: proc(app: ^App, dw, dh: int) {
	nw := clamp(app.grid.width + dw, 1, orca.MAX_DIM)
	nh := clamp(app.grid.height + dh, 1, orca.MAX_DIM)
	if nw == app.grid.width && nh == app.grid.height {
		return
	}
	push_undo(app)
	ng := orca.resize_grid(app.grid, nw, nh)
	orca.destroy_grid(&app.grid)
	app.grid = ng
	delete(app.marks)
	app.marks = orca.make_marks(app.grid)
	app.cursor_x = clamp(app.cursor_x, 0, nw - 1)
	app.cursor_y = clamp(app.cursor_y, 0, nh - 1)
	app.sel_active = false
	app.dirty = true
	set_status(app, fmt.aprintf("%dx%d", nw, nh))
}

//------//
// UNDO //
//------//

// Snapshot the grid and cursor before a mutating edit. Coalescing is left to
// callers; every call here records one undo step. Oldest steps past UNDO_MAX
// are dropped.
push_undo :: proc(app: ^App) {
	snap := Undo_Snapshot {
		cells    = make([]u8, len(app.grid.cells)),
		width    = app.grid.width,
		height   = app.grid.height,
		cursor_x = app.cursor_x,
		cursor_y = app.cursor_y,
	}
	copy(snap.cells, app.grid.cells)
	append(&app.undo, snap)
	if len(app.undo) > UNDO_MAX {
		delete(app.undo[0].cells)
		ordered_remove(&app.undo, 0)
	}
}

// Restore the most recent snapshot, replacing the current grid (and rebuilding
// marks if the dimensions changed).
undo :: proc(app: ^App) {
	if len(app.undo) == 0 {
		set_status(app, fmt.aprintf("nothing to undo"))
		return
	}
	snap := pop(&app.undo)
	resized := snap.width != app.grid.width || snap.height != app.grid.height
	orca.destroy_grid(&app.grid)
	app.grid = orca.Grid {
		cells  = snap.cells, // transfer ownership of the snapshot buffer
		width  = snap.width,
		height = snap.height,
	}
	if resized {
		delete(app.marks)
		app.marks = orca.make_marks(app.grid)
	}
	app.cursor_x = clamp(snap.cursor_x, 0, app.grid.width - 1)
	app.cursor_y = clamp(snap.cursor_y, 0, app.grid.height - 1)
	app.sel_active = false
	app.dirty = true
	set_status(app, fmt.aprintf("undo (%d left)", len(app.undo)))
}

clear_undo :: proc(app: ^App) {
	for snap in app.undo {
		delete(snap.cells)
	}
	delete(app.undo)
	app.undo = nil
}

//------------//
// SIMULATION //
//------------//

// Cap on ticks consumed per rendered frame, so a stall (window drag,
// sleep) doesn't fire a burst of catch-up ticks. (Mallorca policy;
// orca-c has no such cap.)
MAX_TICKS_PER_FRAME :: 8

step_tick :: proc(app: ^App) {
	orca.run_tick(app.grid, app.marks, app.tick, 0, &app.events)
	advance_notes(app) // expire notes triggered on earlier ticks first
	dispatch_events(app) // then emit this tick's events (and schedule new notes)
	app.tick += 1
	app.dirty = false
}

// Count down every sustained note by one frame; send note-off for any that
// reach the end of their duration.
advance_notes :: proc(app: ^App) {
	i := 0
	for i < len(app.sus) {
		app.sus[i].frames -= 1
		if app.sus[i].frames <= 0 {
			midi_note_off(&app.midi, app.sus[i].channel, app.sus[i].note)
			unordered_remove(&app.sus, i)
		} else {
			i += 1
		}
	}
}

// Turn this tick's VM events into MIDI. OSC ('=') and UDP (';') are network
// transports and remain deferred; the VM still produces them.
dispatch_events :: proc(app: ^App) {
	for ev in app.events {
		switch e in ev {
		case orca.Midi_Note_Event:
			note := u8(clamp(int(e.octave)*12 + int(e.note), 0, 127))
			if e.mono {
				stop_channel(app, e.channel) // '%' steals its channel
			}
			midi_note_on(&app.midi, e.channel, note, e.velocity)
			append(&app.sus, Sus_Note{channel = e.channel, note = note, frames = max(int(e.duration), 1)})
		case orca.Midi_CC_Event:
			midi_cc(&app.midi, e.channel, e.control, e.value)
		case orca.Midi_PB_Event:
			midi_pitch_bend(&app.midi, e.channel, e.lsb, e.msb)
		case orca.Osc_Ints_Event: // deferred
		case orca.Udp_String_Event: // deferred
		}
	}
}

// Send note-off for and drop every sustained note on `channel` (monophony).
stop_channel :: proc(app: ^App, channel: u8) {
	i := 0
	for i < len(app.sus) {
		if app.sus[i].channel == channel {
			midi_note_off(&app.midi, app.sus[i].channel, app.sus[i].note)
			unordered_remove(&app.sus, i)
		} else {
			i += 1
		}
	}
}

// Silence and forget all sustained notes (pause, quit, or device change).
flush_notes :: proc(app: ^App) {
	for n in app.sus {
		midi_note_off(&app.midi, n.channel, n.note)
	}
	clear(&app.sus)
}

update_sim :: proc(app: ^App) {
	if app.playing {
		app.accum += k2.get_frame_time()
		frame := frame_seconds(app.bpm)
		ticks := 0
		for app.accum >= frame && ticks < MAX_TICKS_PER_FRAME {
			app.accum -= frame
			step_tick(app)
			ticks += 1
		}
		if app.accum >= frame {
			// Drop whole overdue ticks but keep the fractional phase, so
			// a stall doesn't shift subsequent tick deadlines.
			app.accum = math.mod(app.accum, frame)
		}
	} else if app.dirty {
		// Fresh highlighting while paused: compute marks from a scratch
		// copy of the grid without advancing the simulation.
		orca.preview_marks(app.grid, app.marks, app.tick, 0)
		app.dirty = false
	}
}

save :: proc(app: ^App) {
	if app.file_name == "" {
		app.file_name = DEFAULT_FILE_NAME
	}
	data := orca.serialize_field(app.grid, context.temp_allocator)
	err := os.write_entire_file(app.file_name, data)
	if err != nil {
		set_status(app, fmt.aprintf("save failed: %v", err))
	} else {
		set_status(app, fmt.aprintf("saved %s", app.file_name))
	}
}

STATUS_MSG_SECONDS :: 2.0

// Takes ownership of `msg` (heap-allocated); freed when it expires.
set_status :: proc(app: ^App, msg: string) {
	if app.status_msg != "" {
		delete(app.status_msg)
	}
	app.status_msg = msg
	app.status_timer = STATUS_MSG_SECONDS
}

// Advance the cursor blink. Any cursor movement resets the phase to fully
// visible, so the cursor never blinks away the instant you move or type.
update_blink :: proc(app: ^App) {
	if app.cursor_x != app.blink_x || app.cursor_y != app.blink_y {
		app.blink = 0
		app.blink_x = app.cursor_x
		app.blink_y = app.cursor_y
	}
	app.blink += k2.get_frame_time()
}

// True during the "on" half of the blink cycle.
cursor_visible :: proc(app: ^App) -> bool {
	return int(app.blink / BLINK_INTERVAL) % 2 == 0
}

tick_status :: proc(app: ^App) {
	if app.status_timer <= 0 {
		return
	}
	app.status_timer -= k2.get_frame_time()
	if app.status_timer <= 0 && app.status_msg != "" {
		delete(app.status_msg)
		app.status_msg = ""
	}
}

Layout :: struct {
	cell_w:    f32,
	cell_h:    f32,
	font_size: f32,
}

// The grid always spans the full window width; cell and font size follow.
compute_layout :: proc(grid: orca.Grid) -> Layout {
	cell_w := (f32(k2.get_screen_width()) - MARGIN*2) / f32(grid.width)
	font_size := cell_w / ADVANCE_EM
	return Layout{cell_w = cell_w, cell_h = font_size * LINE_EM, font_size = font_size}
}

// Solid frame just inside the window edges signalling play state:
// green while playing, nothing while paused.
draw_border :: proc(app: ^App) {
	// Green frame while playing, or while the Enter audition tone sounds.
	if !app.playing && !app.audition {
		return
	}
	rect := k2.Rect{
		BORDER_INSET,
		BORDER_INSET,
		f32(k2.get_screen_width()) - BORDER_INSET*2,
		f32(k2.get_screen_height()) - BORDER_INSET*2,
	}
	k2.draw_rect_outline(rect, BORDER_THICKNESS, PLAY_BORDER)
}

// Muted fill behind the selected rectangle, drawn under the glyphs.
draw_selection :: proc(app: ^App, layout: Layout) {
	if !app.sel_active {
		return
	}
	x0, y0, x1, y1 := selection_rect(app)
	rect := k2.Rect{
		MARGIN + f32(x0)*layout.cell_w,
		MARGIN + f32(y0)*layout.cell_h,
		f32(x1 - x0 + 1)*layout.cell_w,
		f32(y1 - y0 + 1)*layout.cell_h,
	}
	k2.draw_rect(rect, SELECT)
}

draw_grid :: proc(grid: orca.Grid, marks: []orca.Mark, font: k2.Font, layout: Layout) {
	buf: [1]u8
	for y in 0 ..< grid.height {
		for x in 0 ..< grid.width {
			glyph := orca.grid_get(grid, x, y)
			mark := marks[y*grid.width + x]
			pos := k2.Vec2{MARGIN + f32(x)*layout.cell_w, MARGIN + f32(y)*layout.cell_h}
			color := FG
			if glyph == orca.EMPTY_GLYPH {
				// Ruler overlay: '+' every 8x8 intersection, dim '.' elsewhere.
				if x % RULER_SPACING == 0 && y % RULER_SPACING == 0 {
					glyph = '+'
					color = RULER
				} else {
					color = DIM
				}
			}
			// Marks style empty cells too, matching orca-c's tui; haste
			// wins over output (orca-c applies it last).
			switch {
			case .Haste_Input in mark:
				color = HASTE
			case .Output in mark:
				// Freshly written cells draw inverted, like Orca.
				rect := k2.Rect{pos.x, pos.y, layout.cell_w, layout.cell_h}
				k2.draw_rect(rect, OUTPUT_BG)
				color = OUTPUT_FG
			case .Input in mark:
				color = INPUT
			case .Lock in mark:
				color = LOCKED
			}
			buf[0] = glyph
			k2.draw_text(string(buf[:]), pos, layout.font_size, color, font)
		}
	}
}

// Inverted cell at the cursor; empty cells show '@' (like Orca) so the
// cursor is always visible.
draw_cursor :: proc(app: ^App, font: k2.Font, layout: Layout) {
	// Off half of the blink: skip the cursor so the underlying cell shows.
	if !cursor_visible(app) {
		return
	}
	glyph := orca.grid_get(app.grid, app.cursor_x, app.cursor_y)
	if glyph == orca.EMPTY_GLYPH {
		glyph = '@'
	}
	pos := k2.Vec2{MARGIN + f32(app.cursor_x)*layout.cell_w, MARGIN + f32(app.cursor_y)*layout.cell_h}
	rect := k2.Rect{pos.x, pos.y, layout.cell_w, layout.cell_h}
	k2.draw_rect(rect, CURSOR_BG)
	buf := [1]u8{glyph}
	k2.draw_text(string(buf[:]), pos, layout.font_size, CURSOR_FG, font)
}

draw_status :: proc(app: ^App, font: k2.Font, layout: Layout) {
	text: string
	if app.status_msg != "" {
		text = app.status_msg
	} else {
		name := app.file_name if app.file_name != "" else "(unsaved)"
		mode := "  play" if app.playing else "  stop"
		if app.insert_mode {
			mode = fmt.tprintf("%s  ins", mode)
		}
		if app.midi.ok {
			mode = fmt.tprintf("%s  midi%s", mode, "+dev" if app.midi.has_dest else "")
		}
		text = fmt.tprintf(
			"%s   %dx%d   %d,%d   %df   %dbpm%s",
			name,
			app.grid.width,
			app.grid.height,
			app.cursor_x,
			app.cursor_y,
			app.tick,
			app.bpm,
			mode,
		)
	}
	// The status line is heads-up/debug info, so draw it smaller than the
	// grid glyphs (60%) to keep it fitting within the window width.
	size := layout.font_size * STATUS_SCALE
	y := f32(k2.get_screen_height()) - size - MARGIN
	k2.draw_text(text, {MARGIN, y}, size, STATUS, font)
}
