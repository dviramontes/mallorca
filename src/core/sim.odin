// The Orca VM: a faithful port of orca-c's sim.c.
// One call to run_tick scans the grid top-left to bottom-right, evaluating
// operators. Uppercase letters run every frame, lowercase on neighboring
// '*' bang. Marks and events are cleared and rewritten each tick.
package core

GLYPH_COUNT :: 36

@(rodata)
GLYPH_TABLE := [GLYPH_COUNT]u8 {
	'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b',
	'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n',
	'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
}

glyph_of :: proc(index: uint) -> u8 {
	assert(index < GLYPH_COUNT)
	return GLYPH_TABLE[index]
}

index_of :: proc(c_: u8) -> uint {
	c := c_ & 0x7f // sim.c indexes `index_table[c & 0x7f]`
	switch {
	case c >= '0' && c <= '9':
		return uint(c - '0')
	case c >= 'A' && c <= 'Z':
		return uint(c - 'A' + 10)
	case c >= 'a' && c <= 'z':
		return uint(c - 'a' + 10)
	}
	return 0
}

glyph_is_lowercase :: proc(g: u8) -> bool {
	return g & (1 << 5) != 0
}

glyph_lowered :: proc(g: u8) -> u8 {
	return g | (1 << 5)
}

// Result takes the case of `caser` for letters; digits pass through.
// Bit trick ported verbatim from sim.c.
glyph_with_case :: proc(g, caser: u8) -> u8 {
	CASE_BIT :: u8(1 << 5)
	ALPHA_BIT :: u8(1 << 6)
	return (g &~ CASE_BIT) | ((~g & ALPHA_BIT) >> 1) | (caser & CASE_BIT)
}

@(rodata)
NOTE_SEMIS := [7]u8{0, 2, 4, 5, 7, 9, 11}

// Returns 255 if not a valid note glyph (A-Z a-z; lowercase = sharp).
midi_note_number_of :: proc(g: u8) -> u8 {
	sharp := (g & (1 << 5)) >> 5
	up := g &~ u8(1 << 5)
	if up < 'A' || up > 'Z' {
		return 255
	}
	// C=0, D=1, ... A and B are equivalent to H and I.
	deg := int('G' - 'B' + up - 'A') if up <= 'B' else int(up - 'C')
	return u8(deg/7*12 + int(NOTE_SEMIS[deg%7])) + sharp
}

//-----------------//
// SIM CONTEXT     //
//-----------------//

@(private = "file")
Sim :: struct {
	cells:  []u8,
	marks:  []Mark,
	width:  int,
	height: int,
	tick:   uint,
	seed:   uint,
	vars:   [GLYPH_COUNT]u8,
	events: ^[dynamic]Event,
}

@(private = "file")
peek :: proc(s: ^Sim, y, x, dy, dx: int) -> u8 {
	y0, x0 := y + dy, x + dx
	if y0 < 0 || x0 < 0 || y0 >= s.height || x0 >= s.width {
		return '.'
	}
	return s.cells[y0*s.width + x0]
}

@(private = "file")
poke :: proc(s: ^Sim, y, x, dy, dx: int, g: u8) {
	y0, x0 := y + dy, x + dx
	if y0 < 0 || x0 < 0 || y0 >= s.height || x0 >= s.width {
		return
	}
	s.cells[y0*s.width + x0] = g
}

@(private = "file")
mark_rel :: proc(s: ^Sim, y, x, dy, dx: int, flags: Mark) {
	y0, x0 := y + dy, x + dx
	if y0 < 0 || x0 < 0 || y0 >= s.height || x0 >= s.width {
		return
	}
	s.marks[y0*s.width + x0] += flags
}

@(private = "file")
stun :: proc(s: ^Sim, y, x, dy, dx: int) {
	mark_rel(s, y, x, dy, dx, {.Sleep})
}

@(private = "file")
poke_stunned :: proc(s: ^Sim, y, x, dy, dx: int, g: u8) {
	y0, x0 := y + dy, x + dx
	if y0 < 0 || x0 < 0 || y0 >= s.height || x0 >= s.width {
		return
	}
	s.cells[y0*s.width + x0] = g
	s.marks[y0*s.width + x0] += {.Sleep}
}

@(private = "file")
lock_rel :: proc(s: ^Sim, y, x, dy, dx: int) {
	mark_rel(s, y, x, dy, dx, {.Lock})
}

IN :: Mark{.Input}
OUT :: Mark{.Output}
PARAM :: Mark{.Haste_Input}
NONLOCKING :: Mark{.Lock}

// Ports lock their operand cells by default; passing NONLOCKING (the lock
// flag itself) cancels that via symmetric difference — same trick as
// orca-c's `(_flags) ^ Mark_flag_lock`.
@(private = "file")
port :: proc(s: ^Sim, y, x, dy, dx: int, flags: Mark) {
	mark_rel(s, y, x, dy, dx, flags ~ {.Lock})
}

@(private = "file")
has_neighboring_bang :: proc(s: ^Sim, y, x: int) -> bool {
	return(
		peek(s, y, x, 0, 1) == '*' ||
		peek(s, y, x, 0, -1) == '*' ||
		peek(s, y, x, 1, 0) == '*' ||
		peek(s, y, x, -1, 0) == '*' \
	)
}

// LOWERCASE_REQUIRES_BANG / STOP_IF_NOT_BANGED in sim.c.
@(private = "file")
lowercase_requires_bang :: proc(s: ^Sim, y, x: int, ch: u8) -> bool {
	return glyph_is_lowercase(ch) && !has_neighboring_bang(s, y, x)
}

//-----------//
// OPERATORS //
//-----------//

@(private = "file")
op_movement :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	dy, dx := 0, 0
	switch glyph_lowered(ch) {
	case 'n':
		dy = -1
	case 'e':
		dx = 1
	case 's':
		dy = 1
	case 'w':
		dx = -1
	}
	y0, x0 := y + dy, x + dx
	if y0 < 0 || x0 < 0 || y0 >= s.height || x0 >= s.width {
		s.cells[y*s.width + x] = '*'
		return
	}
	dest := y0*s.width + x0
	if s.cells[dest] == '.' {
		s.cells[dest] = ch
		s.cells[y*s.width + x] = '.'
		s.marks[dest] += {.Sleep}
	} else {
		s.cells[y*s.width + x] = '*'
	}
}

@(private = "file")
op_midicc :: proc(s: ^Sim, y, x: int, ch: u8) {
	for i in 1 ..< 4 {
		port(s, y, x, 0, i, IN)
	}
	if !has_neighboring_bang(s, y, x) {
		return
	}
	channel_g := peek(s, y, x, 0, 1)
	control_g := peek(s, y, x, 0, 2)
	value_g := peek(s, y, x, 0, 3)
	if channel_g == '.' || control_g == '.' {
		return
	}
	channel := index_of(channel_g)
	if channel > 15 {
		return
	}
	port(s, y, x, 0, 0, OUT)
	append(s.events, Midi_CC_Event{
		channel = u8(channel),
		control = u8(index_of(control_g)),
		value   = u8(index_of(value_g) * 127 / 35), // 0~35 -> 0~127
	})
}

@(private = "file")
op_comment :: proc(s: ^Sim, y, x: int, ch: u8) {
	max_x := min(x + 255, s.width)
	for x0 in x + 1 ..< max_x {
		g := s.cells[y*s.width + x0]
		s.marks[y*s.width + x0] += {.Lock}
		if g == '#' {
			break
		}
	}
}

@(private = "file")
op_bang :: proc(s: ^Sim, y, x: int, ch: u8) {
	s.cells[y*s.width + x] = '.'
}

// ':' (poly) and '%' (mono).
@(private = "file")
op_midi :: proc(s: ^Sim, y, x: int, ch: u8) {
	for i in 1 ..< 6 {
		port(s, y, x, 0, i, IN)
	}
	if !has_neighboring_bang(s, y, x) {
		return
	}
	channel_g := peek(s, y, x, 0, 1)
	octave_g := peek(s, y, x, 0, 2)
	note_g := peek(s, y, x, 0, 3)
	velocity_g := peek(s, y, x, 0, 4)
	length_g := peek(s, y, x, 0, 5)
	if octave_g == '.' {
		return
	}
	octave := min(u8(index_of(octave_g)), 9)
	note := midi_note_number_of(note_g)
	if note == 255 {
		return
	}
	channel := min(index_of(channel_g), 15)
	velocity: uint
	if velocity_g == '.' {
		velocity = 127 // unspecified velocity = full
	} else {
		velocity = index_of(velocity_g)
		if velocity == 0 {
			return // zero-velocity note is a note-off; do nothing
		}
		velocity = min(velocity*8 - 1, 127) // 1~16 -> 7~127
	}
	port(s, y, x, 0, 0, OUT)
	append(s.events, Midi_Note_Event{
		channel  = u8(channel),
		octave   = octave,
		note     = note,
		velocity = u8(velocity),
		duration = u8(index_of(length_g) & 0x7f),
		mono     = ch == '%',
	})
}

@(private = "file")
op_udp :: proc(s: ^Sim, y, x: int, ch: u8) {
	n := min(s.width - x - 1, UDP_STRING_COUNT)
	cpy: [UDP_STRING_COUNT]u8
	count := 0
	for i in 0 ..< n {
		g := s.cells[y*s.width + x + 1 + i]
		if g == '.' {
			break
		}
		cpy[i] = g
		s.marks[y*s.width + x + 1 + i] += {.Lock}
		count += 1
	}
	if !has_neighboring_bang(s, y, x) {
		return
	}
	port(s, y, x, 0, 0, OUT)
	append(s.events, Udp_String_Event{count = u8(count), chars = cpy})
}

@(private = "file")
op_osc :: proc(s: ^Sim, y, x: int, ch: u8) {
	port(s, y, x, 0, 1, IN + PARAM)
	port(s, y, x, 0, 2, IN + PARAM)
	length := min(int(index_of(peek(s, y, x, 0, 2))), OSC_INT_COUNT)
	for i in 0 ..< length {
		port(s, y, x, 0, i + 3, IN)
	}
	if !has_neighboring_bang(s, y, x) {
		return
	}
	g := peek(s, y, x, 0, 1)
	if g == '.' {
		return
	}
	port(s, y, x, 0, 0, OUT)
	ev := Osc_Ints_Event{glyph = g, count = u8(length)}
	for i in 0 ..< length {
		ev.numbers[i] = u8(index_of(peek(s, y, x, 0, i + 3)))
	}
	append(s.events, ev)
}

@(private = "file")
op_midipb :: proc(s: ^Sim, y, x: int, ch: u8) {
	for i in 1 ..< 4 {
		port(s, y, x, 0, i, IN)
	}
	if !has_neighboring_bang(s, y, x) {
		return
	}
	channel_g := peek(s, y, x, 0, 1)
	msb_g := peek(s, y, x, 0, 2)
	lsb_g := peek(s, y, x, 0, 3)
	if channel_g == '.' {
		return
	}
	channel := index_of(channel_g)
	if channel > 15 {
		return
	}
	port(s, y, x, 0, 0, OUT)
	append(s.events, Midi_PB_Event{
		channel = u8(channel),
		msb     = u8(index_of(msb_g) * 127 / 35), // 0~35 -> 0~127
		lsb     = u8(index_of(lsb_g) * 127 / 35),
	})
}

@(private = "file")
op_add :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	port(s, y, x, 1, 0, OUT)
	a := peek(s, y, x, 0, -1)
	b := peek(s, y, x, 0, 1)
	g := GLYPH_TABLE[(index_of(a) + index_of(b)) % GLYPH_COUNT]
	poke(s, y, x, 1, 0, glyph_with_case(g, b))
}

@(private = "file")
op_subtract :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	port(s, y, x, 1, 0, OUT)
	a := peek(s, y, x, 0, -1)
	b := peek(s, y, x, 0, 1)
	val := abs(int(index_of(b)) - int(index_of(a)))
	poke(s, y, x, 1, 0, glyph_with_case(glyph_of(uint(val)), b))
}

@(private = "file")
op_clock :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	port(s, y, x, 1, 0, OUT)
	b := peek(s, y, x, 0, 1)
	rate := max(index_of(peek(s, y, x, 0, -1)), 1)
	mod_num := index_of(b)
	if mod_num == 0 {
		mod_num = 8
	}
	g := glyph_of(s.tick / rate % mod_num)
	poke(s, y, x, 1, 0, glyph_with_case(g, b))
}

@(private = "file")
op_delay :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	port(s, y, x, 1, 0, OUT)
	rate := max(index_of(peek(s, y, x, 0, -1)), 1)
	mod_num := index_of(peek(s, y, x, 0, 1))
	if mod_num == 0 {
		mod_num = 8
	}
	g := u8('*') if s.tick % (rate * mod_num) == 0 else u8('.')
	poke(s, y, x, 1, 0, g)
}

@(private = "file")
op_if :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	port(s, y, x, 1, 0, OUT)
	g0 := peek(s, y, x, 0, -1)
	g1 := peek(s, y, x, 0, 1)
	poke(s, y, x, 1, 0, '*' if g0 == g1 else '.')
}

@(private = "file")
op_generator :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	out_x := int(index_of(peek(s, y, x, 0, -3)))
	out_y := int(index_of(peek(s, y, x, 0, -2))) + 1
	length := int(index_of(peek(s, y, x, 0, -1)))
	port(s, y, x, 0, -3, IN + PARAM) // x
	port(s, y, x, 0, -2, IN + PARAM) // y
	port(s, y, x, 0, -1, IN + PARAM) // len
	for i in 0 ..< length {
		port(s, y, x, 0, i + 1, IN)
		port(s, y, x, out_y, out_x + i, OUT + NONLOCKING)
		g := peek(s, y, x, 0, i + 1)
		poke_stunned(s, y, x, out_y, out_x + i, g)
	}
}

@(private = "file")
op_halt :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 1, 0, IN + PARAM)
}

@(private = "file")
op_increment :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	port(s, y, x, 1, 0, IN + OUT)
	ga := peek(s, y, x, 0, -1)
	gb := peek(s, y, x, 0, 1)
	rate: uint = 1
	if ga != '.' && ga != '*' {
		rate = index_of(ga)
	}
	max_num := index_of(gb)
	if max_num == 0 {
		max_num = 36
	}
	val := (index_of(peek(s, y, x, 1, 0)) + rate) % max_num
	poke(s, y, x, 1, 0, glyph_with_case(glyph_of(val), gb))
}

@(private = "file")
op_jump :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	g := peek(s, y, x, -1, 0)
	if g == 'J' {
		return
	}
	port(s, y, x, -1, 0, IN)
	for i in 1 ..= 256 {
		if peek(s, y, x, i, 0) != ch {
			port(s, y, x, i, 0, OUT)
			poke(s, y, x, i, 0, g)
			break
		}
		stun(s, y, x, i, 0)
	}
}

@(private = "file")
op_konkat :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	length := max(int(index_of(peek(s, y, x, 0, -1))), 1)
	port(s, y, x, 0, -1, IN + PARAM)
	for i in 0 ..< length {
		port(s, y, x, 0, i + 1, IN)
		v := peek(s, y, x, 0, i + 1)
		if v != '.' {
			port(s, y, x, 1, i + 1, OUT)
			poke(s, y, x, 1, i + 1, s.vars[index_of(v)])
		}
	}
}

@(private = "file")
op_lesser :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	port(s, y, x, 1, 0, OUT)
	ga := peek(s, y, x, 0, -1)
	gb := peek(s, y, x, 0, 1)
	if ga == '.' || gb == '.' {
		poke(s, y, x, 1, 0, '.')
	} else {
		out := min(index_of(ga), index_of(gb))
		poke(s, y, x, 1, 0, glyph_with_case(glyph_of(out), gb))
	}
}

@(private = "file")
op_multiply :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	port(s, y, x, 1, 0, OUT)
	a := peek(s, y, x, 0, -1)
	b := peek(s, y, x, 0, 1)
	g := GLYPH_TABLE[(index_of(a) * index_of(b)) % GLYPH_COUNT]
	poke(s, y, x, 1, 0, glyph_with_case(g, b))
}

@(private = "file")
op_offset :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	in_x := int(index_of(peek(s, y, x, 0, -2))) + 1
	in_y := int(index_of(peek(s, y, x, 0, -1)))
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, -2, IN + PARAM)
	port(s, y, x, in_y, in_x, IN)
	port(s, y, x, 1, 0, OUT)
	poke(s, y, x, 1, 0, peek(s, y, x, in_y, in_x))
}

@(private = "file")
op_push :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	key := index_of(peek(s, y, x, 0, -2))
	length := index_of(peek(s, y, x, 0, -1))
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, -2, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	if length == 0 {
		return
	}
	out_x := int(key % length)
	for i in 0 ..< int(length) {
		lock_rel(s, y, x, 1, i)
	}
	port(s, y, x, 1, out_x, OUT)
	poke(s, y, x, 1, out_x, peek(s, y, x, 0, 1))
}

@(private = "file")
op_query :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	in_x := int(index_of(peek(s, y, x, 0, -3))) + 1
	in_y := int(index_of(peek(s, y, x, 0, -2)))
	length := int(index_of(peek(s, y, x, 0, -1)))
	out_x := 1 - length
	port(s, y, x, 0, -3, IN + PARAM) // x
	port(s, y, x, 0, -2, IN + PARAM) // y
	port(s, y, x, 0, -1, IN + PARAM) // len
	for i in 0 ..< length {
		port(s, y, x, in_y, in_x + i, IN)
		port(s, y, x, 1, out_x + i, OUT)
		g := peek(s, y, x, in_y, in_x + i)
		poke(s, y, x, 1, out_x + i, g)
	}
}

@(private = "file")
op_random :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	port(s, y, x, 1, 0, OUT)
	gb := peek(s, y, x, 0, 1)
	a := index_of(peek(s, y, x, 0, -1))
	b := index_of(gb)
	if b == 0 {
		b = 36
	}
	lo, hi: uint
	if a == b {
		poke(s, y, x, 1, 0, glyph_of(a))
		return
	} else if a < b {
		lo, hi = a, b
	} else {
		lo, hi = b, a
	}
	// 32-bit shift_mult hash in size_t arithmetic, verbatim from sim.c.
	key := (s.seed + uint(y*s.width + x)) ~ (s.tick << 16)
	key = (key ~ 61) ~ (key >> 16)
	key = key + (key << 3)
	key = key ~ (key >> 4)
	key = key * 0x27d4eb2d
	key = key ~ (key >> 15)
	val := key % (hi - lo) + lo
	poke(s, y, x, 1, 0, glyph_with_case(glyph_of(val), gb))
}

@(private = "file")
op_track :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	key := index_of(peek(s, y, x, 0, -2))
	length := index_of(peek(s, y, x, 0, -1))
	port(s, y, x, 0, -2, IN + PARAM)
	port(s, y, x, 0, -1, IN + PARAM)
	if length == 0 {
		return
	}
	read_val_x := int(key%length) + 1
	for i in 0 ..< int(length) {
		lock_rel(s, y, x, 0, i + 1)
	}
	port(s, y, x, 0, read_val_x, IN)
	port(s, y, x, 1, 0, OUT)
	poke(s, y, x, 1, 0, peek(s, y, x, 0, read_val_x))
}

@(private = "file")
op_uclid :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	port(s, y, x, 1, 0, OUT)
	left := peek(s, y, x, 0, -1)
	steps: uint = 1
	if left != '.' && left != '*' {
		steps = index_of(left)
	}
	max_num := index_of(peek(s, y, x, 0, 1))
	if max_num == 0 {
		max_num = 8
	}
	bucket := (steps * (s.tick + max_num - 1)) % max_num + steps
	g := u8('*') if bucket >= max_num else u8('.')
	poke(s, y, x, 1, 0, g)
}

@(private = "file")
op_variable :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	left := peek(s, y, x, 0, -1)
	right := peek(s, y, x, 0, 1)
	if left != '.' {
		// write
		s.vars[index_of(left)] = right
	} else if right != '.' {
		// read
		port(s, y, x, 1, 0, OUT)
		poke(s, y, x, 1, 0, s.vars[index_of(right)])
	}
}

@(private = "file")
op_teleport :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	out_x := int(index_of(peek(s, y, x, 0, -2)))
	out_y := int(index_of(peek(s, y, x, 0, -1))) + 1
	port(s, y, x, 0, -2, IN + PARAM) // x
	port(s, y, x, 0, -1, IN + PARAM) // y
	port(s, y, x, 0, 1, IN)
	port(s, y, x, out_y, out_x, OUT + NONLOCKING)
	poke_stunned(s, y, x, out_y, out_x, peek(s, y, x, 0, 1))
}

@(private = "file")
op_yump :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	g := peek(s, y, x, 0, -1)
	if g == 'Y' {
		return
	}
	port(s, y, x, 0, -1, IN)
	for i in 1 ..= 256 {
		if peek(s, y, x, 0, i) != ch {
			port(s, y, x, 0, i, OUT)
			poke(s, y, x, 0, i, g)
			break
		}
		stun(s, y, x, 0, i)
	}
}

@(private = "file")
op_lerp :: proc(s: ^Sim, y, x: int, ch: u8) {
	if lowercase_requires_bang(s, y, x, ch) {
		return
	}
	port(s, y, x, 0, -1, IN + PARAM)
	port(s, y, x, 0, 1, IN)
	port(s, y, x, 1, 0, IN + OUT)
	g := peek(s, y, x, 0, -1)
	b := peek(s, y, x, 0, 1)
	rate := 1 if g == '.' || g == '*' else int(index_of(g))
	goal := int(index_of(b))
	val := int(index_of(peek(s, y, x, 1, 0)))
	mod: int
	if val <= goal - rate {
		mod = rate
	} else if val >= goal + rate {
		mod = -rate
	} else {
		mod = goal - val
	}
	poke(s, y, x, 1, 0, glyph_with_case(glyph_of(uint(val + mod)), b))
}

//----------------//
// RUN SIMULATION //
//----------------//

// Advance the simulation one tick. Mutates grid.cells; clears and rewrites
// marks and events. Equivalent to orca-c's
// mbuffer_clear + oevent_list_clear + orca_run.
run_tick :: proc(grid: Grid, marks: []Mark, tick, seed: uint, events: ^[dynamic]Event) {
	assert(len(marks) == len(grid.cells))
	clear_marks(marks)
	clear(events)

	s := Sim {
		cells  = grid.cells,
		marks  = marks,
		width  = grid.width,
		height = grid.height,
		tick   = tick,
		seed   = seed,
		events = events,
	}
	for &v in s.vars {
		v = '.'
	}

	for y in 0 ..< s.height {
		for x in 0 ..< s.width {
			g := s.cells[y*s.width + x]
			if g == '.' {
				continue
			}
			if s.marks[y*s.width + x] & {.Lock, .Sleep} != {} {
				continue
			}
			switch g {
			case '!':
				op_midicc(&s, y, x, g)
			case '#':
				op_comment(&s, y, x, g)
			case '%', ':':
				op_midi(&s, y, x, g)
			case '*':
				op_bang(&s, y, x, g)
			case ';':
				op_udp(&s, y, x, g)
			case '=':
				op_osc(&s, y, x, g)
			case '?':
				op_midipb(&s, y, x, g)
			case 'A', 'a':
				op_add(&s, y, x, g)
			case 'B', 'b':
				op_subtract(&s, y, x, g)
			case 'C', 'c':
				op_clock(&s, y, x, g)
			case 'D', 'd':
				op_delay(&s, y, x, g)
			case 'E', 'e', 'N', 'n', 'S', 's', 'W', 'w':
				op_movement(&s, y, x, g)
			case 'F', 'f':
				op_if(&s, y, x, g)
			case 'G', 'g':
				op_generator(&s, y, x, g)
			case 'H', 'h':
				op_halt(&s, y, x, g)
			case 'I', 'i':
				op_increment(&s, y, x, g)
			case 'J', 'j':
				op_jump(&s, y, x, g)
			case 'K', 'k':
				op_konkat(&s, y, x, g)
			case 'L', 'l':
				op_lesser(&s, y, x, g)
			case 'M', 'm':
				op_multiply(&s, y, x, g)
			case 'O', 'o':
				op_offset(&s, y, x, g)
			case 'P', 'p':
				op_push(&s, y, x, g)
			case 'Q', 'q':
				op_query(&s, y, x, g)
			case 'R', 'r':
				op_random(&s, y, x, g)
			case 'T', 't':
				op_track(&s, y, x, g)
			case 'U', 'u':
				op_uclid(&s, y, x, g)
			case 'V', 'v':
				op_variable(&s, y, x, g)
			case 'X', 'x':
				op_teleport(&s, y, x, g)
			case 'Y', 'y':
				op_yump(&s, y, x, g)
			case 'Z', 'z':
				op_lerp(&s, y, x, g)
			}
		}
	}
}

// Compute fresh marks for display while paused: runs a tick against a
// scratch copy of the grid, keeps the marks, discards grid changes and
// events — same trick as orca-c's tui. Scratch storage comes from
// `allocator`; with the default temp allocator the caller must free it
// (e.g. per-frame free_all) after use.
preview_marks :: proc(grid: Grid, marks: []Mark, tick, seed: uint, allocator := context.temp_allocator) {
	scratch := Grid {
		cells  = make([]u8, len(grid.cells), allocator),
		width  = grid.width,
		height = grid.height,
	}
	copy(scratch.cells, grid.cells)
	events := make([dynamic]Event, allocator)
	run_tick(scratch, marks, tick, seed, &events)
}
