// Raw C-ABI binding for the fofoca mesh engine — structs mirroring
// crates/fofoca-ffi/include/fofoca.h exactly, and nothing else. No policy, no
// state machine: that is `package p2p` one level up.
//
// The engine exports `fofoca_open` / `fofoca_recv` / …; each C symbol is
// pinned per proc with `@(link_name)` so the Odin side reads bare — `open`,
// `recv`, `send`. The room opener is `start`, not `open`, precisely so these
// can keep the names the header uses.
#+build darwin
package p2p

import "core:c"
import "core:mem"
import "core:strings"

foreign import fofoca_ffi {"../../fofoca/lib/libfofoca_ffi.a", "system:Security.framework", "system:SystemConfiguration.framework", "system:CoreWLAN.framework", "system:SecurityFoundation.framework", "system:Foundation.framework", "system:CoreFoundation.framework", "system:objc", "system:iconv"}

// Opaque handle to an open mesh pipe.
Pipe :: struct {}

Opts :: struct {
	mesh:      cstring,
	topic:     cstring,
	nick:      cstring,
	name:      cstring,
	is_public: c.int,
	mdns:      c.int,
	dht:       c.int,
	relay:     c.int,
	max_peers: c.size_t,
}

Frame :: struct {
	nick:     [64]u8,
	directed: c.int,
	eof:      c.int,
	len:      c.size_t,
}

@(default_calling_convention = "c")
foreign fofoca_ffi {
	@(link_name = "fofoca_open")
	open :: proc(opts: ^Opts) -> ^Pipe ---
	@(link_name = "fofoca_id")
	id :: proc(h: ^Pipe) -> cstring ---
	@(link_name = "fofoca_name")
	name :: proc(h: ^Pipe) -> cstring ---
	@(link_name = "fofoca_nickname")
	nickname :: proc(h: ^Pipe) -> cstring ---
	// recv one frame into buf (cap bytes), waiting up to timeout_ms. Blocks the
	// calling thread, so only the mesh worker may call it. Returns 1 (frame
	// ready, frame.len says how many bytes of buf are valid), 0 (nothing
	// pending), or -1 (error, see last_error).
	@(link_name = "fofoca_recv")
	recv :: proc(h: ^Pipe, buf: [^]u8, cap: c.size_t, timeout_ms: c.int, frame: ^Frame) -> c.long ---
	// to == nil broadcasts; otherwise a directed send to that nickname.
	@(link_name = "fofoca_send")
	send :: proc(h: ^Pipe, to: cstring, buf: [^]u8, len: c.size_t) -> c.long ---
	@(link_name = "fofoca_send_eof")
	send_eof :: proc(h: ^Pipe, to: cstring) -> c.long ---
	// Needed-length protocol: buf == nil (cap ignored) returns the required
	// buffer size; call again with a big-enough buffer to fill it.
	@(link_name = "fofoca_peers_json")
	peers_json :: proc(h: ^Pipe, buf: [^]u8, cap: c.size_t) -> c.long ---
	@(link_name = "fofoca_state_json")
	state_json :: proc(h: ^Pipe, buf: [^]u8, cap: c.size_t) -> c.long ---
	@(link_name = "fofoca_state_merge")
	state_merge :: proc(h: ^Pipe, merge_json: cstring) -> c.long ---
	@(link_name = "fofoca_peer_count")
	peer_count :: proc(h: ^Pipe) -> c.long ---
	@(link_name = "fofoca_max_chunk")
	max_chunk :: proc(h: ^Pipe) -> c.size_t ---
	@(link_name = "fofoca_close")
	close :: proc(h: ^Pipe) ---
	// No handle: must be callable when open itself failed.
	@(link_name = "fofoca_last_error")
	last_error :: proc() -> cstring ---
	@(link_name = "fofoca_version")
	version :: proc() -> cstring ---
}

// Must match fofoca's `GOSSIP_ACTIVE_VIEW_CAPACITY` — what the engine uses
// when Opts.max_peers == 0.
DEFAULT_MAX_PEERS :: 64

// Fill `buf` via the needed-length protocol shared by peers_json and
// state_json: probe for the required size, allocate, fill. Returns "" on
// error or an empty document.
//
// copy_out NUL-terminates and only writes when `needed < cap`, so the buffer
// must be larger than the reported length. A document that grows between
// probe and fill is retried — otherwise we'd return an unwritten (zeroed)
// buffer, fail JSON parse, and look like an empty roster.
//
// `allocator` is deliberately not defaulted: these documents are produced on
// the mesh worker thread and consumed on the render thread, and Odin's
// temp_allocator is per-thread — a default would silently hand main a string
// the worker frees at the end of its next loop iteration.
@(private = "file")
sized_json :: proc(
	h: ^Pipe,
	fn: proc "c" (h: ^Pipe, buf: [^]u8, cap: c.size_t) -> c.long,
	allocator: mem.Allocator,
) -> string {
	cap_hint := 0
	for _ in 0 ..< 4 {
		needed := fn(h, nil, 0)
		if needed <= 0 {
			return ""
		}
		// +1 for NUL; +64 slack so a peer joining mid-read still fits.
		ncap := max(int(needed) + 1 + 64, cap_hint)
		buf := make([]u8, ncap, allocator)
		n := fn(h, raw_data(buf), c.size_t(len(buf)))
		if n <= 0 {
			return ""
		}
		if int(n) < len(buf) {
			return string(buf[:n])
		}
		// Wrote nothing (needed >= cap); retry with the new size.
		cap_hint = int(n) + 1 + 64
	}
	return ""
}

peers_json_string :: proc(h: ^Pipe, allocator: mem.Allocator) -> string {
	return sized_json(h, peers_json, allocator)
}

state_json_string :: proc(h: ^Pipe, allocator: mem.Allocator) -> string {
	return sized_json(h, state_json, allocator)
}

// Clone a borrowed cstring (valid only for the handle's lifetime) into an
// owned Odin string. Returns "" for a nil cstring.
clone_cstring :: proc(s: cstring, allocator := context.allocator) -> string {
	if s == nil {
		return ""
	}
	out, _ := strings.clone_from_cstring(s, allocator)
	return out
}

// The engine stores the last error in a `thread_local!` slot (ffi.rs), so this
// only ever reports errors from calls made on *this* thread. The mesh worker
// must therefore capture its own failures right where they happen and hand the
// message to the render thread itself — main calling this after a worker-side
// error reads its own empty slot.
last_error_string :: proc(allocator := context.temp_allocator) -> string {
	return clone_cstring(last_error(), allocator)
}
