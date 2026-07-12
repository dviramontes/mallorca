// CoreMIDI output for mallorca (M5). macOS-only, like the rest of the host.
//
// We always publish a virtual source named "mallorca" that any app can
// subscribe to, and additionally send to the first hardware destination if
// one is present. The note scheduler lives in main.odin; this file only
// owns the CoreMIDI handles and the raw byte sends.
#+build darwin
package main

import "core:fmt"

foreign import midi "system:CoreMIDI.framework"
foreign import core_foundation "system:CoreFoundation.framework"
foreign import system_lib "system:System.framework"

// CoreMIDI object handles are UInt32 tokens, not pointers.
MIDIObjectRef :: distinct u32
MIDIClientRef :: MIDIObjectRef
MIDIPortRef :: MIDIObjectRef
MIDIEndpointRef :: MIDIObjectRef
MIDITimeStamp :: u64
ItemCount :: u64 // CoreMIDI's ItemCount is unsigned long (64-bit on macOS)
OSStatus :: i32

CFStringRef :: rawptr
CFAllocatorRef :: rawptr
CFStringEncoding :: u32
kCFStringEncodingUTF8 :: CFStringEncoding(0x0800_0100)

MIDINotifyProc :: #type proc "c" (message: rawptr, refCon: rawptr)

// CoreMIDI declares these under `#pragma pack(push, 4)`, so `packet` sits at
// offset 4, not the natural-alignment offset 8. #packed reproduces that exact
// layout (timeStamp@4, length@12, data@14 within the list) — without it,
// CoreMIDI reads `length` from the wrong offset and forwards garbage. We only
// ever send one short packet.
MIDIPacket :: struct #packed {
	timeStamp: MIDITimeStamp,
	length:    u16,
	data:      [256]u8,
}

MIDIPacketList :: struct #packed {
	numPackets: u32,
	packet:     MIDIPacket,
}

@(default_calling_convention = "c")
foreign midi {
	MIDIClientCreate :: proc(name: CFStringRef, notifyProc: MIDINotifyProc, notifyRefCon: rawptr, outClient: ^MIDIClientRef) -> OSStatus ---
	MIDISourceCreate :: proc(client: MIDIClientRef, name: CFStringRef, outSrc: ^MIDIEndpointRef) -> OSStatus ---
	MIDIOutputPortCreate :: proc(client: MIDIClientRef, name: CFStringRef, outPort: ^MIDIPortRef) -> OSStatus ---
	MIDIGetNumberOfDestinations :: proc() -> ItemCount ---
	MIDIGetDestination :: proc(index: ItemCount) -> MIDIEndpointRef ---
	MIDIReceived :: proc(src: MIDIEndpointRef, pktlist: ^MIDIPacketList) -> OSStatus ---
	MIDISend :: proc(port: MIDIPortRef, dest: MIDIEndpointRef, pktlist: ^MIDIPacketList) -> OSStatus ---
	MIDIClientDispose :: proc(client: MIDIClientRef) -> OSStatus ---
}

@(default_calling_convention = "c")
foreign core_foundation {
	CFStringCreateWithCString :: proc(alloc: CFAllocatorRef, cStr: cstring, encoding: CFStringEncoding) -> CFStringRef ---
	CFRelease :: proc(obj: rawptr) ---
}

// CoreMIDI timestamps are mach host-time ticks. Stamping packets with the
// real current time (not 0) is what lets timing-sensitive receivers like
// GarageBand/Logic actually play the events.
@(default_calling_convention = "c")
foreign system_lib {
	mach_absolute_time :: proc() -> u64 ---
}

Midi :: struct {
	client:   MIDIClientRef,
	source:   MIDIEndpointRef, // virtual source, always created
	port:     MIDIPortRef,     // output port for the hardware destination
	dest:     MIDIEndpointRef, // first hardware destination, if any
	has_dest: bool,
	ok:       bool,
	debug:    bool, // --debug: log every MIDI message to stderr
	sent:     int,  // running count of messages emitted (for --debug output)
}

@(private = "file")
cfstr :: proc(s: cstring) -> CFStringRef {
	return CFStringCreateWithCString(nil, s, kCFStringEncodingUTF8)
}

midi_init :: proc(debug := false) -> (m: Midi) {
	m.debug = debug
	name := cfstr("mallorca")
	defer CFRelease(name)
	if MIDIClientCreate(name, nil, nil, &m.client) != 0 {
		return // ok stays false; sends become no-ops
	}

	src_name := cfstr("mallorca out")
	defer CFRelease(src_name)
	MIDISourceCreate(m.client, src_name, &m.source)

	port_name := cfstr("mallorca port")
	defer CFRelease(port_name)
	MIDIOutputPortCreate(m.client, port_name, &m.port)

	if MIDIGetNumberOfDestinations() > 0 {
		m.dest = MIDIGetDestination(0)
		m.has_dest = m.dest != 0
	}
	m.ok = m.source != 0 || m.has_dest
	if m.debug {
		fmt.eprintfln(
			"midi: source=%d hardware_destinations=%d ok=%v",
			m.source,
			MIDIGetNumberOfDestinations(),
			m.ok,
		)
	}
	return
}

midi_shutdown :: proc(m: ^Midi) {
	if m.client != 0 {
		MIDIClientDispose(m.client)
	}
	m^ = {}
}

// Send one short (status + two data bytes) MIDI message to the virtual
// source and, if present, the hardware destination.
@(private = "file")
send3 :: proc(m: ^Midi, b0, b1, b2: u8) {
	if !m.ok {
		return
	}
	pkts: MIDIPacketList
	pkts.numPackets = 1
	pkts.packet.timeStamp = mach_absolute_time() // "now" in host ticks
	pkts.packet.length = 3
	pkts.packet.data[0] = b0
	pkts.packet.data[1] = b1
	pkts.packet.data[2] = b2
	if m.source != 0 {
		MIDIReceived(m.source, &pkts)
	}
	if m.has_dest {
		MIDISend(m.port, m.dest, &pkts)
	}
	m.sent += 1
	if m.debug {
		fmt.eprintfln("midi tx #%d: %02x %02x %02x", m.sent, b0, b1, b2)
	}
}

midi_note_on :: proc(m: ^Midi, channel, note, velocity: u8) {
	send3(m, 0x90 | (channel & 0x0f), note & 0x7f, velocity & 0x7f)
}

midi_note_off :: proc(m: ^Midi, channel, note: u8) {
	send3(m, 0x80 | (channel & 0x0f), note & 0x7f, 0)
}

midi_cc :: proc(m: ^Midi, channel, control, value: u8) {
	send3(m, 0xb0 | (channel & 0x0f), control & 0x7f, value & 0x7f)
}

midi_pitch_bend :: proc(m: ^Midi, channel, lsb, msb: u8) {
	send3(m, 0xe0 | (channel & 0x0f), lsb & 0x7f, msb & 0x7f)
}
