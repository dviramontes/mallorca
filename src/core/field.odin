// Field: the Orca grid, a flat buffer of glyphs with dimensions.
// Mirrors orca-c's field.c, but parse/serialize operate on byte slices;
// the host owns all filesystem access.
package core

EMPTY_GLYPH :: u8('.')

// orca-c rejects grids larger than 4096 in either dimension.
MAX_DIM :: 4096

Grid :: struct {
	cells:  []u8,
	width:  int,
	height: int,
}

make_grid :: proc(
	width, height: int,
	fill := EMPTY_GLYPH,
	allocator := context.allocator,
) -> Grid {
	assert(width > 0 && height > 0)
	cells := make([]u8, width * height, allocator)
	for &c in cells {
		c = fill
	}
	return Grid{cells = cells, width = width, height = height}
}

destroy_grid :: proc(grid: ^Grid, allocator := context.allocator) {
	delete(grid.cells, allocator)
	grid^ = {}
}

grid_get :: proc(grid: Grid, x, y: int) -> u8 {
	if x < 0 || y < 0 || x >= grid.width || y >= grid.height {
		return EMPTY_GLYPH
	}
	return grid.cells[y * grid.width + x]
}

grid_set :: proc(grid: Grid, x, y: int, glyph: u8) {
	if x < 0 || y < 0 || x >= grid.width || y >= grid.height {
		return
	}
	grid.cells[y * grid.width + x] = glyph
}

// Return a new grid of (width, height), copying the overlapping top-left
// region of `src`; cells outside that region are EMPTY_GLYPH. Does not
// free `src` — the caller owns both grids.
resize_grid :: proc(src: Grid, width, height: int, allocator := context.allocator) -> Grid {
	dst := make_grid(width, height, allocator = allocator)
	for y in 0 ..< min(height, src.height) {
		for x in 0 ..< min(width, src.width) {
			dst.cells[y * width + x] = src.cells[y * src.width + x]
		}
	}
	return dst
}

Parse_Error :: enum {
	None,
	No_Rows,
	Not_A_Rectangle,
	Too_Large,
	Invalid_Char,
}

// Parse an .orca file: rectangular lines of printable-ASCII glyphs.
// Dimensions come from the file; non-rectangular input is rejected,
// same as orca-c's field_load_file.
parse_field :: proc(data: []u8, allocator := context.allocator) -> (grid: Grid, err: Parse_Error) {
	width, height := 0, 0
	line_start := 0
	i := 0
	for i <= len(data) {
		at_end := i == len(data)
		if at_end || data[i] == '\n' {
			line_len := i - line_start
			if line_len > 0 && data[i - 1] == '\r' {
				line_len -= 1
			}
			if line_len > 0 {
				if line_len > MAX_DIM {
					return {}, .Too_Large
				}
				if width == 0 {
					width = line_len
				} else if line_len != width {
					return {}, .Not_A_Rectangle
				}
				height += 1
				if height > MAX_DIM {
					return {}, .Too_Large
				}
			} else if !at_end && width > 0 {
				// blank line in the middle of the grid
				if i + 1 < len(data) {
					return {}, .Not_A_Rectangle
				}
			}
			line_start = i + 1
		}
		i += 1
	}
	if height == 0 {
		return {}, .No_Rows
	}

	grid = make_grid(width, height, allocator = allocator)
	x, y := 0, 0
	for c in data {
		switch c {
		case '\n':
			if x > 0 {
				x = 0
				y += 1
			}
		case '\r':
		// ignored
		case ' ':
			grid_set(grid, x, y, EMPTY_GLYPH)
			x += 1
		case '!' ..= '~':
			grid_set(grid, x, y, c)
			x += 1
		case:
			destroy_grid(&grid, allocator)
			return {}, .Invalid_Char
		}
	}
	return grid, .None
}

// Serialize a grid to .orca file bytes: one line per row, '\n' after each.
serialize_field :: proc(grid: Grid, allocator := context.allocator) -> []u8 {
	out := make([]u8, (grid.width + 1) * grid.height, allocator)
	i := 0
	for y in 0 ..< grid.height {
		for x in 0 ..< grid.width {
			out[i] = grid_get(grid, x, y)
			i += 1
		}
		out[i] = '\n'
		i += 1
	}
	return out
}
