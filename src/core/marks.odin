// Per-cell mark flags, mirroring orca-c's Mark_flags (gbuffer.h).
// The mark buffer is per-tick scratch output: cleared at the start of
// every tick, written during the scan, read by the UI for highlighting.
package core

Mark_Flag :: enum u8 {
	Input, // cell is read as an operand
	Output, // cell is written as a result
	Haste_Input, // operand read on the hasted (left/upper) side
	Lock, // cell must not execute as an operator this tick
	Sleep, // cell was just written; skip execution this tick
	Projected, // cell is inside a generator's destination region
}

Mark :: bit_set[Mark_Flag;u8]

make_marks :: proc(grid: Grid, allocator := context.allocator) -> []Mark {
	return make([]Mark, grid.width * grid.height, allocator)
}

clear_marks :: proc(marks: []Mark) {
	for &m in marks {
		m = {}
	}
}
