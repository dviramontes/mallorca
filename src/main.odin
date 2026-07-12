// mallorca — native Odin port of Orca.
// M2: grid display + cursor + editing + save. No simulation, no MIDI yet.
package main

import "core:fmt"
import "core:os"
import NS "core:sys/darwin/Foundation" // macOS-only for now; gate with #+build when porting
import k2 "../karl2d"
import orca "core"

FONT_DATA :: #load("../assets/JetBrainsMono-Regular.ttf")

// Font size used only to compute the initial window dimensions; after
// that, the grid scales to fill the window width.
INITIAL_FONT_SIZE :: 32
MARGIN :: 16

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

DEFAULT_W :: 57
DEFAULT_H :: 25

DEFAULT_FILE_NAME :: "untitled.orca"

App :: struct {
	grid:         orca.Grid,
	file_name:    string,
	cursor_x:     int,
	cursor_y:     int,
	status_msg:   string, // transient message shown in the status bar
	status_timer: f32,
	repeat:       [len(REPEAT_KEYS)]f32,
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

	window_w := MARGIN*2 + app.grid.width*(INITIAL_FONT_SIZE * 3 / 5)
	window_h := MARGIN*2 + app.grid.height*(INITIAL_FONT_SIZE * 23 / 20) + INITIAL_FONT_SIZE + 12
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
			tick_status(&app)

			layout := compute_layout(app.grid)
			k2.clear(BG)
			draw_grid(app.grid, font, layout)
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
	}

	if ctrl_held() {
		if k2.key_went_down(.S) {
			save(app)
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
		}
	}

	// Digits and symbols.
	for gk in GLYPH_KEYS {
		if k2.key_went_down(gk.key) {
			glyph := gk.shifted if shift else gk.base
			if glyph != 0 {
				orca.grid_set(app.grid, app.cursor_x, app.cursor_y, glyph)
			}
		}
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

draw_grid :: proc(grid: orca.Grid, font: k2.Font, layout: Layout) {
	buf: [1]u8
	for y in 0 ..< grid.height {
		for x in 0 ..< grid.width {
			glyph := orca.grid_get(grid, x, y)
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
			buf[0] = glyph
			pos := k2.Vec2{MARGIN + f32(x)*layout.cell_w, MARGIN + f32(y)*layout.cell_h}
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
			"%s   %dx%d   %d,%d   0f   120bpm",
			name,
			app.grid.width,
			app.grid.height,
			app.cursor_x,
			app.cursor_y,
		)
	}
	y := f32(k2.get_screen_height()) - layout.font_size - 6
	k2.draw_text(text, {MARGIN, y}, layout.font_size, STATUS, font)
}
