// mallorca — native Odin port of Orca.
// M1: window + grid display. No cursor, no simulation, no MIDI yet.
package main

import "core:fmt"
import "core:os"
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

DEFAULT_W :: 57
DEFAULT_H :: 25

main :: proc() {
	grid: orca.Grid
	file_name := ""
	if len(os.args) > 1 && os.args[1] != "" {
		file_name = os.args[1]
		data, read_err := os.read_entire_file_from_path(file_name, context.allocator)
		if read_err != nil {
			fmt.eprintfln("mallorca: cannot read %q: %v", file_name, read_err)
			os.exit(1)
		}
		g, err := orca.parse_field(data)
		delete(data)
		if err != .None {
			fmt.eprintfln("mallorca: failed to load %q: %v", file_name, err)
			os.exit(1)
		}
		grid = g
	} else {
		grid = orca.make_grid(DEFAULT_W, DEFAULT_H)
	}

	window_w := MARGIN*2 + grid.width*(INITIAL_FONT_SIZE * 3 / 5)
	window_h := MARGIN*2 + grid.height*(INITIAL_FONT_SIZE * 23 / 20) + INITIAL_FONT_SIZE + 12
	k2.init(window_w, window_h, "mallorca", {window_mode = .Windowed_Resizable})
	defer k2.shutdown()

	// Dynamic font: bakes glyphs on demand, so it stays sharp at any
	// window-derived size.
	font := k2.load_dynamic_font_from_bytes(FONT_DATA)
	defer k2.destroy_font(font)

	for k2.update() {
		if k2.key_is_held(.Left_Control) && k2.key_went_down(.Q) {
			break
		}

		layout := compute_layout(grid)
		k2.clear(BG)
		draw_grid(grid, font, layout)
		draw_status(grid, file_name, font, layout)
		k2.present()

		free_all(context.temp_allocator)
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

draw_status :: proc(grid: orca.Grid, file_name: string, font: k2.Font, layout: Layout) {
	name := file_name if file_name != "" else "(unsaved)"
	text := fmt.tprintf("%s   %dx%d   0f   120bpm", name, grid.width, grid.height)
	y := f32(k2.get_screen_height()) - layout.font_size - 6
	k2.draw_text(text, {MARGIN, y}, layout.font_size, STATUS, font)
}
