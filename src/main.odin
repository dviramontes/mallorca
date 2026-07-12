// mallorca — native Odin port of Orca.
// M3: grid display + editing + running simulation. Events are produced
// each tick but not delivered anywhere yet (MIDI is M5).
package main

import "core:fmt"
import "core:math"
import "core:os"
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

DEFAULT_W :: 57
DEFAULT_H :: 25

DEFAULT_FILE_NAME :: "untitled.orca"

DEFAULT_BPM :: 120

App :: struct {
	grid:         orca.Grid,
	file_name:    string,
	cursor_x:     int,
	cursor_y:     int,
	status_msg:   string, // transient message shown in the status bar
	status_timer: f32,
	repeat:       [len(REPEAT_KEYS)]f32,

	// Simulation state.
	marks:        []orca.Mark,
	events:       [dynamic]orca.Event, // produced each tick; unused until M5
	tick:         uint,
	bpm:          int,
	playing:      bool,
	accum:        f32, // elapsed seconds not yet consumed by ticks
	dirty:        bool, // grid edited while paused; marks need a preview
}

// Four VM frames per beat — orca-c's timing rule. The single source of
// truth for tick length (M5 note scheduling must reuse this).
frame_seconds :: proc(bpm: int) -> f32 {
	return 60.0 / f32(bpm) / 4.0
}

main :: proc() {
	app: App
	if len(os.args) > 1 && os.args[1] != "" {
		app.file_name = os.args[1]
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
	app.marks = orca.make_marks(app.grid)
	app.bpm = DEFAULT_BPM
	app.dirty = true // preview marks for the freshly loaded grid
	defer orca.destroy_grid(&app.grid)
	defer delete(app.marks)
	defer delete(app.events)
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
			tick_status(&app)

			layout := compute_layout(app.grid)
			k2.clear(BG)
			draw_border(&app)
			draw_grid(app.grid, app.marks, font, layout)
			draw_cursor(&app, font, layout)
			draw_status(&app, font, layout)
			k2.present()

			free_all(context.temp_allocator)
		}

		pool->drain()
		if quit {
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
	// Cursor movement, with key repeat.
	if key_repeats(app, 0, .Left) {app.cursor_x -= 1}
	if key_repeats(app, 1, .Right) {app.cursor_x += 1}
	if key_repeats(app, 2, .Up) {app.cursor_y -= 1}
	if key_repeats(app, 3, .Down) {app.cursor_y += 1}
	app.cursor_x = clamp(app.cursor_x, 0, app.grid.width - 1)
	app.cursor_y = clamp(app.cursor_y, 0, app.grid.height - 1)

	// Clearing.
	if key_repeats(app, 4, .Backspace) || k2.key_went_down(.Delete) || k2.key_went_down(.Period) {
		orca.grid_set(app.grid, app.cursor_x, app.cursor_y, orca.EMPTY_GLYPH)
		app.dirty = true
	}

	// Play/pause.
	if k2.key_went_down(.Space) {
		app.playing = !app.playing
		app.accum = 0
		set_status(app, fmt.aprintf("%s", "playing" if app.playing else "paused"))
	}

	if ctrl_held() {
		if k2.key_went_down(.S) {
			save(app)
		}
		if k2.key_went_down(.F) {
			step_tick(app) // single-step one frame (orca-c's Ctrl+F)
		}
		return // don't treat shortcut keys as glyph input
	}

	// Letters: unshifted lowercase (on-bang ops), shifted uppercase
	// (every-frame ops). Keyboard_Key values match ASCII uppercase.
	shift := shift_held()
	for key in k2.Keyboard_Key.A ..= k2.Keyboard_Key.Z {
		if k2.key_went_down(key) {
			glyph := u8(key)
			if !shift {
				glyph += 'a' - 'A'
			}
			orca.grid_set(app.grid, app.cursor_x, app.cursor_y, glyph)
			app.dirty = true
		}
	}

	// Digits and symbols.
	for gk in GLYPH_KEYS {
		if k2.key_went_down(gk.key) {
			glyph := gk.shifted if shift else gk.base
			if glyph != 0 {
				orca.grid_set(app.grid, app.cursor_x, app.cursor_y, glyph)
				app.dirty = true
			}
		}
	}
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
	app.tick += 1
	app.dirty = false
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
	if !app.playing {
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
		text = fmt.tprintf(
			"%s   %dx%d   %d,%d   %df   %dbpm   %s",
			name,
			app.grid.width,
			app.grid.height,
			app.cursor_x,
			app.cursor_y,
			app.tick,
			app.bpm,
			"play" if app.playing else "stop",
		)
	}
	y := f32(k2.get_screen_height()) - layout.font_size - MARGIN
	k2.draw_text(text, {MARGIN, y}, layout.font_size, STATUS, font)
}
