// Events emitted by I/O operators; logical equivalents of orca-c's
// Oevent (vmio.h), using a native tagged union rather than its C layout.
// The VM only produces these; the host decides what to do with them
// (delivery is a later milestone — until then they are discarded).
package core

Event :: union {
	Midi_Note_Event,
	Midi_CC_Event,
	Midi_PB_Event,
	Osc_Ints_Event,
	Udp_String_Event,
}

// ':' (polyphonic) and '%' (monophonic) operators.
Midi_Note_Event :: struct {
	channel:  u8,
	octave:   u8,
	note:     u8, // semitones above C, may exceed 11 (e.g. 'c' = C# + octave)
	velocity: u8, // 0-127
	duration: u8, // in frames, 0-127
	mono:     bool,
}

// '!' operator.
Midi_CC_Event :: struct {
	channel: u8,
	control: u8,
	value:   u8, // 0-127
}

// '?' operator (pitch bend).
Midi_PB_Event :: struct {
	channel: u8,
	lsb:     u8, // 0-127
	msb:     u8, // 0-127
}

OSC_INT_COUNT :: 35

// '=' operator.
Osc_Ints_Event :: struct {
	glyph:   u8, // OSC path selector glyph
	count:   u8,
	numbers: [OSC_INT_COUNT]u8,
}

UDP_STRING_COUNT :: 16

// ';' operator.
Udp_String_Event :: struct {
	count: u8,
	chars: [UDP_STRING_COUNT]u8,
}
