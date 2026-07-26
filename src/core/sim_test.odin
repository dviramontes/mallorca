package core

import "core:testing"

//---------//
// HELPERS //
//---------//

// Parse `src`, run `ticks` ticks, and expect the serialized grid to equal
// `expected` (both use one '\n' per row). Returns the events from the
// final tick for further inspection.
@(private = "file")
run_ticks :: proc(
	t: ^testing.T,
	src: string,
	ticks: uint,
	expected: string,
	seed: uint = 0,
	loc := #caller_location,
) -> [dynamic]Event {
	grid, err := parse_field(transmute([]u8)src, context.temp_allocator)
	testing.expect_value(t, err, Parse_Error.None, loc = loc)
	marks := make_marks(grid, context.temp_allocator)
	events := make([dynamic]Event, context.temp_allocator)
	for i in 0 ..< ticks {
		run_tick(grid, marks, i, seed, &events)
	}
	got := serialize_field(grid, context.temp_allocator)
	testing.expect_value(t, string(got), expected, loc = loc)
	return events
}

@(test)
test_glyph_index_roundtrip :: proc(t: ^testing.T) {
	testing.expect_value(t, index_of('0'), uint(0))
	testing.expect_value(t, index_of('9'), uint(9))
	testing.expect_value(t, index_of('a'), uint(10))
	testing.expect_value(t, index_of('A'), uint(10))
	testing.expect_value(t, index_of('z'), uint(35))
	testing.expect_value(t, index_of('Z'), uint(35))
	testing.expect_value(t, index_of('.'), uint(0))
	testing.expect_value(t, index_of('*'), uint(0))
	// sim.c masks with 0x7f before the table lookup.
	testing.expect_value(t, index_of(0xC1), index_of('A'))
	for i in uint(0) ..< GLYPH_COUNT {
		testing.expect_value(t, index_of(glyph_of(i)), i)
	}
}

@(test)
test_glyph_with_case :: proc(t: ^testing.T) {
	// Letters take the caser's case; digits pass through unchanged.
	testing.expect_value(t, glyph_with_case('a', 'B'), u8('A'))
	testing.expect_value(t, glyph_with_case('A', 'b'), u8('a'))
	testing.expect_value(t, glyph_with_case('5', 'b'), u8('5'))
	testing.expect_value(t, glyph_with_case('5', 'B'), u8('5'))
}

@(test)
test_midi_note_numbers :: proc(t: ^testing.T) {
	testing.expect_value(t, midi_note_number_of('C'), u8(0))
	testing.expect_value(t, midi_note_number_of('c'), u8(1)) // C#
	testing.expect_value(t, midi_note_number_of('D'), u8(2))
	testing.expect_value(t, midi_note_number_of('A'), u8(9))
	testing.expect_value(t, midi_note_number_of('B'), u8(11))
	testing.expect_value(t, midi_note_number_of('H'), u8(9)) // H ≡ A
	testing.expect_value(t, midi_note_number_of('I'), u8(11)) // I ≡ B
	testing.expect_value(t, midi_note_number_of('0'), u8(255))
	testing.expect_value(t, midi_note_number_of('.'), u8(255))
}

//-----------//
// OPERATORS //
//-----------//

@(test)
test_op_add :: proc(t: ^testing.T) {
	run_ticks(t, "1A2\n...\n", 1, "1A2\n.3.\n")
	// Output takes the case of the right operand (b = 11, 1+11 = 12 = 'c').
	run_ticks(t, "1Ab\n...\n", 1, "1Ab\n.c.\n")
}

@(test)
test_op_subtract :: proc(t: ^testing.T) {
	run_ticks(t, "5B2\n...\n", 1, "5B2\n.3.\n")
	// Absolute difference.
	run_ticks(t, "2B5\n...\n", 1, "2B5\n.3.\n")
}

@(test)
test_op_multiply :: proc(t: ^testing.T) {
	run_ticks(t, "3M4\n...\n", 1, "3M4\n.c.\n") // 12 = 'c', digit caser keeps lowercase table glyph
}

@(test)
test_op_clock :: proc(t: ^testing.T) {
	// C with rate 1, mod 4: outputs tick % 4.
	run_ticks(t, ".C4\n...\n", 1, ".C4\n.0.\n")
	run_ticks(t, ".C4\n...\n", 4, ".C4\n.3.\n")
	run_ticks(t, ".C4\n...\n", 5, ".C4\n.0.\n")
}

@(test)
test_op_delay :: proc(t: ^testing.T) {
	// D with rate 1, mod 2 bangs every 2nd tick (tick 0 bangs; the bang
	// erases itself next tick before D rewrites it).
	run_ticks(t, ".D2\n...\n", 1, ".D2\n.*.\n")
	run_ticks(t, ".D2\n...\n", 2, ".D2\n...\n")
	run_ticks(t, ".D2\n...\n", 3, ".D2\n.*.\n")
}

@(test)
test_op_if :: proc(t: ^testing.T) {
	run_ticks(t, "3F3\n...\n", 1, "3F3\n.*.\n")
	run_ticks(t, "3F4\n...\n", 1, "3F4\n...\n")
}

@(test)
test_op_increment :: proc(t: ^testing.T) {
	run_ticks(t, ".I4\n.0.\n", 1, ".I4\n.1.\n")
	run_ticks(t, ".I4\n.0.\n", 4, ".I4\n.0.\n") // wraps at 4
}

@(test)
test_op_movement :: proc(t: ^testing.T) {
	// E moves east one cell per tick.
	run_ticks(t, "E..\n", 1, ".E.\n")
	run_ticks(t, "E..\n", 2, "..E\n")
	// Hitting the wall explodes into a bang, which then erases itself.
	run_ticks(t, "E..\n", 3, "..*\n")
	run_ticks(t, "E..\n", 4, "...\n")
	// Collision with a non-empty cell also bangs.
	run_ticks(t, "E1.\n", 1, "*1.\n")
}

@(test)
test_lowercase_requires_bang :: proc(t: ^testing.T) {
	// Lowercase 'a' does nothing without a neighboring bang...
	run_ticks(t, "1a2\n...\n", 1, "1a2\n...\n")
	// ...and runs when banged. The bang must come after the operator in
	// scan order (a bare '*' erases itself when scanned); here 'a' both
	// sees the '*' below and overwrites it with its output.
	run_ticks(t, "1a2\n.*.\n", 1, "1a2\n.3.\n")
}

@(test)
test_bang_before_operator_is_gone :: proc(t: ^testing.T) {
	// A bang north of an operator is erased before the operator is
	// scanned, so it does NOT trigger it — orca-c scan-order quirk.
	run_ticks(t, ".*.\n1a2\n...\n", 1, "...\n1a2\n...\n")
}

@(test)
test_op_bang_erases :: proc(t: ^testing.T) {
	run_ticks(t, "*\n", 1, ".\n")
}

@(test)
test_op_comment_locks :: proc(t: ^testing.T) {
	// Operators between #...# are locked and do not run.
	run_ticks(t, "#1A2#\n.....\n", 1, "#1A2#\n.....\n")
}

@(test)
test_op_east_locked_by_comment :: proc(t: ^testing.T) {
	run_ticks(t, "#E.#\n", 1, "#E.#\n")
}

@(test)
test_op_generator :: proc(t: ^testing.T) {
	// G with x='.', y='.', len=1: copies its east operand below itself.
	run_ticks(t, "..1G5\n.....\n", 1, "..1G5\n...5.\n")
}

@(test)
test_op_jump :: proc(t: ^testing.T) {
	run_ticks(t, "1\nJ\n.\n", 1, "1\nJ\n1\n")
}

@(test)
test_op_yump :: proc(t: ^testing.T) {
	run_ticks(t, "1Y.\n", 1, "1Y1\n")
}

@(test)
test_op_variable :: proc(t: ^testing.T) {
	// Write 'aV5' then read 'Va' within the same tick (scan order).
	// The read V outputs directly below itself.
	run_ticks(t, "aV5....\n....Va.\n.......\n", 1, "aV5....\n....Va.\n....5..\n")
}

@(test)
test_op_random_deterministic :: proc(t: ^testing.T) {
	// Same tick + seed => same value (pinned); value stays within [a, b).
	run_ticks(t, ".R5\n...\n", 1, ".R5\n.3.\n", seed = 7)
	run_ticks(t, ".R5\n...\n", 1, ".R5\n.3.\n", seed = 7)
	// a == b outputs a.
	run_ticks(t, "3R3\n...\n", 1, "3R3\n.3.\n")
}

@(test)
test_sleep_written_cell_skipped :: proc(t: ^testing.T) {
	// E moving onto a cell marks it asleep, so the moved glyph does not
	// run again this tick even though the scan hasn't reached it yet.
	run_ticks(t, "E...\n", 1, ".E..\n")
}

@(test)
test_op_halt :: proc(t: ^testing.T) {
	// H locks the cell below, preventing E from running.
	run_ticks(t, "H.\nE.\n", 1, "H.\nE.\n")
}

@(test)
test_op_konkat :: proc(t: ^testing.T) {
	// V writes var 'a'; K reads it and writes below its operand.
	run_ticks(t, "aV5...\n.Ka...\n......\n", 1, "aV5...\n.Ka...\n..5...\n")
}

@(test)
test_op_lesser :: proc(t: ^testing.T) {
	run_ticks(t, "3L5.\n....\n", 1, "3L5.\n.3..\n")
}

@(test)
test_op_offset :: proc(t: ^testing.T) {
	// x='.', y='.': reads one cell east, copies below itself.
	run_ticks(t, "..O1.\n.....\n", 1, "..O1.\n..1..\n")
}

@(test)
test_op_push :: proc(t: ^testing.T) {
	// key=0, len=2: writes input to slot key%len below.
	run_ticks(t, "02P3.\n.....\n", 1, "02P3.\n..3..\n")
}

@(test)
test_op_query :: proc(t: ^testing.T) {
	// x='.', y=1, len=1: reads (1,3), writes ending at its own column.
	run_ticks(t, "11Q...\n...z..\n", 1, "11Q...\n..zz..\n")
}

@(test)
test_op_track :: proc(t: ^testing.T) {
	// key=0, len=2: reads first slot east, copies below itself.
	run_ticks(t, "02T34...\n........\n", 1, "02T34...\n..3.....\n")
}

@(test)
test_op_uclid :: proc(t: ^testing.T) {
	// Defaults steps=1, max=8: bangs on tick 0.
	run_ticks(t, ".U..\n....\n", 1, ".U..\n.*..\n")
}

@(test)
test_op_teleport :: proc(t: ^testing.T) {
	// x='.', y='.': copies its east operand below itself.
	run_ticks(t, "..X1\n....\n", 1, "..X1\n..1.\n")
}

@(test)
test_op_lerp :: proc(t: ^testing.T) {
	// rate=1 toward goal 5: 0 -> 1 after one tick.
	run_ticks(t, ".Z5\n.0.\n", 1, ".Z5\n.1.\n")
}

//-------//
// MARKS //
//-------//

// Parse `src`, run one tick, and return the grid + marks (temp-allocated).
@(private = "file")
tick_marks :: proc(t: ^testing.T, src: string, loc := #caller_location) -> (Grid, []Mark) {
	grid, err := parse_field(transmute([]u8)src, context.temp_allocator)
	testing.expect_value(t, err, Parse_Error.None, loc = loc)
	marks := make_marks(grid, context.temp_allocator)
	events := make([dynamic]Event, context.temp_allocator)
	run_tick(grid, marks, 0, 0, &events)
	return grid, marks
}

@(test)
test_marks_ports :: proc(t: ^testing.T) {
	// A: hasted left operand, normal right operand, locking output.
	grid, marks := tick_marks(t, "1A2\n...\n")
	w := grid.width
	testing.expect_value(t, marks[0*w + 0], Mark{.Input, .Haste_Input, .Lock})
	testing.expect_value(t, marks[0*w + 2], Mark{.Input, .Lock})
	testing.expect_value(t, marks[1*w + 1], Mark{.Output, .Lock})
}

@(test)
test_marks_generator_nonlocking :: proc(t: ^testing.T) {
	// G's projected output is nonlocking, stunned, and identified for rendering.
	grid, marks := tick_marks(t, "..1G5\n.....\n")
	w := grid.width
	testing.expect_value(t, marks[1*w + 3], Mark{.Output, .Sleep, .Projected})
}

@(test)
test_marks_generator_projected_region :: proc(t: ^testing.T) {
	grid, marks := tick_marks(t, "..4G1234\n........\n")
	w := grid.width
	for x in 3 ..= 6 {
		testing.expect(t, .Projected in marks[w + x])
	}
	testing.expect(t, .Projected not_in marks[w + 2])
	testing.expect(t, .Projected not_in marks[w + 7])
}

@(test)
test_marks_movement_sleep :: proc(t: ^testing.T) {
	// A moved glyph's destination is stunned only — no lock, no output.
	grid, marks := tick_marks(t, "E..\n")
	_ = grid
	testing.expect_value(t, marks[1], Mark{.Sleep})
}

@(test)
test_marks_comment_lock :: proc(t: ^testing.T) {
	grid, marks := tick_marks(t, "#a#.\n")
	_ = grid
	testing.expect_value(t, marks[1], Mark{.Lock})
	testing.expect_value(t, marks[2], Mark{.Lock})
	testing.expect_value(t, marks[3], Mark{})
}

//--------------------//
// GOLDEN CONFORMANCE //
//--------------------//

// Expected outputs generated by orca-c's own cli binary
// (commit 9df9786, `cli -t N file`, seed 0), matching PLAN.md M3.

@(test)
test_golden_delay_clock :: proc(t: ^testing.T) {
	// D overwrites the ':' below it with its bang output; the stray 'C'
	// at (4,1) runs as a clock. Quirky on purpose — real orca-c output.
	src :: ".D2...........\n.:04C.........\n..............\n"
	run_ticks(t, src, 1, ".D2...........\n.*04C.........\n....0.........\n")
	run_ticks(t, src, 2, ".D2...........\n..04C.........\n....0.........\n")
	run_ticks(t, src, 3, ".D2...........\n.*04C.........\n....0.........\n")
	run_ticks(t, src, 4, ".D2...........\n..04C.........\n....0.........\n")
}

@(test)
test_golden_clock :: proc(t: ^testing.T) {
	src :: ".C4...........\n..............\n"
	run_ticks(t, src, 1, ".C4...........\n.0............\n")
	run_ticks(t, src, 5, ".C4...........\n.0............\n")
}

@(test)
test_golden_movement :: proc(t: ^testing.T) {
	src :: "E.....\n......\n..N...\n......\nW.S...\n"
	run_ticks(t, src, 1, ".E....\n..N...\n......\n......\n*.*...\n")
	// N collides with E's sleeping destination and bangs; wall bangs erase.
	run_ticks(t, src, 2, "..E...\n..*...\n......\n......\n......\n")
	run_ticks(t, src, 3, "...E..\n......\n......\n......\n......\n")
}

@(test)
test_golden_random_seed0 :: proc(t: ^testing.T) {
	run_ticks(t, ".R5...\n......\n", 1, ".R5...\n.1....\n", seed = 0)
}

//--------//
// EVENTS //
//--------//

// The bang sits SOUTH of each I/O operator: cells earlier in scan order
// self-erase before the operator gets to check for them.

@(test)
test_midi_note_event :: proc(t: ^testing.T) {
	events := run_ticks(t, ":34CFE\n*.....\n", 1, ":34CFE\n......\n")
	testing.expect_value(t, len(events), 1)
	ev, ok := events[0].(Midi_Note_Event)
	testing.expect(t, ok)
	testing.expect_value(t, ev.channel, u8(3))
	testing.expect_value(t, ev.octave, u8(4))
	testing.expect_value(t, ev.note, u8(0)) // C
	testing.expect_value(t, ev.velocity, u8(119)) // f=15 -> min(15*8-1,127)=119
	testing.expect_value(t, ev.duration, u8(14)) // e=14
	testing.expect_value(t, ev.mono, false)
}

@(test)
test_midi_note_event_defaults :: proc(t: ^testing.T) {
	// Unspecified velocity defaults to 127; mono for '%'.
	events := run_ticks(t, "%04C..\n*.....\n", 1, "%04C..\n......\n")
	testing.expect_value(t, len(events), 1)
	ev := events[0].(Midi_Note_Event)
	testing.expect_value(t, ev.velocity, u8(127))
	testing.expect_value(t, ev.mono, true)
}

@(test)
test_midi_note_not_banged :: proc(t: ^testing.T) {
	events := run_ticks(t, ":34C.\n.....\n", 1, ":34C.\n.....\n")
	testing.expect_value(t, len(events), 0)
}

@(test)
test_midi_cc_event :: proc(t: ^testing.T) {
	events := run_ticks(t, "!01z\n*...\n", 1, "!01z\n....\n")
	testing.expect_value(t, len(events), 1)
	ev := events[0].(Midi_CC_Event)
	testing.expect_value(t, ev.channel, u8(0))
	testing.expect_value(t, ev.control, u8(1))
	testing.expect_value(t, ev.value, u8(127)) // z=35 -> 35*127/35
}

@(test)
test_midi_pb_event :: proc(t: ^testing.T) {
	events := run_ticks(t, "?0zz\n*...\n", 1, "?0zz\n....\n")
	testing.expect_value(t, len(events), 1)
	ev := events[0].(Midi_PB_Event)
	testing.expect_value(t, ev.channel, u8(0))
	testing.expect_value(t, ev.msb, u8(127))
	testing.expect_value(t, ev.lsb, u8(127))
}

@(test)
test_osc_event :: proc(t: ^testing.T) {
	events := run_ticks(t, "=a2xy.\n*.....\n", 1, "=a2xy.\n......\n")
	testing.expect_value(t, len(events), 1)
	ev := events[0].(Osc_Ints_Event)
	testing.expect_value(t, ev.glyph, u8('a'))
	testing.expect_value(t, ev.count, u8(2))
	testing.expect_value(t, ev.numbers[0], u8(33)) // x
	testing.expect_value(t, ev.numbers[1], u8(34)) // y
}

@(test)
test_events_ordered_by_scan :: proc(t: ^testing.T) {
	// Multiple emitters fire in scan order (top-left to bottom-right).
	events := run_ticks(
		t,
		":34C..\n*.....\n:02E..\n*.....\n",
		1,
		":34C..\n......\n:02E..\n......\n",
	)
	testing.expect_value(t, len(events), 2)
	ev0 := events[0].(Midi_Note_Event)
	testing.expect_value(t, ev0.channel, u8(3))
	testing.expect_value(t, ev0.note, u8(0)) // C
	ev1 := events[1].(Midi_Note_Event)
	testing.expect_value(t, ev1.channel, u8(0))
	testing.expect_value(t, ev1.note, u8(4)) // E
}

@(test)
test_udp_event :: proc(t: ^testing.T) {
	events := run_ticks(t, ";hi..\n*....\n", 1, ";hi..\n.....\n")
	testing.expect_value(t, len(events), 1)
	ev := events[0].(Udp_String_Event)
	testing.expect_value(t, ev.count, u8(2))
	testing.expect_value(t, ev.chars[0], u8('h'))
	testing.expect_value(t, ev.chars[1], u8('i'))
}
