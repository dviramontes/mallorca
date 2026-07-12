package core

import "core:testing"

@(test)
test_parse_simple :: proc(t: ^testing.T) {
	grid, err := parse_field(transmute([]u8)string("..A..\n.B.C.\n..D..\n"))
	defer destroy_grid(&grid)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, grid.width, 5)
	testing.expect_value(t, grid.height, 3)
	testing.expect_value(t, grid_get(grid, 2, 0), u8('A'))
	testing.expect_value(t, grid_get(grid, 1, 1), u8('B'))
	testing.expect_value(t, grid_get(grid, 3, 1), u8('C'))
	testing.expect_value(t, grid_get(grid, 0, 0), EMPTY_GLYPH)
}

@(test)
test_parse_no_trailing_newline :: proc(t: ^testing.T) {
	grid, err := parse_field(transmute([]u8)string("AB\nCD"))
	defer destroy_grid(&grid)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, grid.width, 2)
	testing.expect_value(t, grid.height, 2)
	testing.expect_value(t, grid_get(grid, 1, 1), u8('D'))
}

@(test)
test_parse_crlf :: proc(t: ^testing.T) {
	grid, err := parse_field(transmute([]u8)string("AB\r\nCD\r\n"))
	defer destroy_grid(&grid)
	testing.expect_value(t, err, Parse_Error.None)
	testing.expect_value(t, grid.width, 2)
	testing.expect_value(t, grid.height, 2)
}

@(test)
test_parse_rejects_ragged :: proc(t: ^testing.T) {
	_, err := parse_field(transmute([]u8)string("ABC\nDE\n"))
	testing.expect_value(t, err, Parse_Error.Not_A_Rectangle)
}

@(test)
test_parse_rejects_empty :: proc(t: ^testing.T) {
	_, err := parse_field(transmute([]u8)string(""))
	testing.expect_value(t, err, Parse_Error.No_Rows)
}

@(test)
test_serialize_roundtrip :: proc(t: ^testing.T) {
	src := "..A..\n.B.C.\n..D..\n"
	grid, err := parse_field(transmute([]u8)string(src))
	defer destroy_grid(&grid)
	testing.expect_value(t, err, Parse_Error.None)
	out := serialize_field(grid)
	defer delete(out)
	testing.expect_value(t, string(out), src)
}

@(test)
test_grid_bounds :: proc(t: ^testing.T) {
	grid := make_grid(3, 3)
	defer destroy_grid(&grid)
	testing.expect_value(t, grid_get(grid, -1, 0), EMPTY_GLYPH)
	testing.expect_value(t, grid_get(grid, 3, 0), EMPTY_GLYPH)
	grid_set(grid, 5, 5, 'X') // out of bounds: no-op, no crash
	testing.expect_value(t, grid_get(grid, 5, 5), EMPTY_GLYPH)
}
