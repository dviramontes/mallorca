// FFI binding for agent-habilis-mesh (P2P rooms, replacing net.odin's
// Phoenix client). Follows src/midi.odin's pattern: foreign import, structs
// mirroring the C header exactly, thin wrappers that clone borrowed cstrings.
//
// mesh_open/mesh_id/mesh_name/mesh_nickname/mesh_send/mesh_send_eof/
// mesh_state_merge/mesh_close/mesh_last_error/mesh_version/mesh_max_chunk
// signatures beyond mesh_recv/mesh_peers_json/mesh_state_json/mesh_peer_count
// are not verbatim in the plan (docs/../.claude/plans/lets-work-on-a-enchanted-spindle.md
// Phase 3) — inferred from naming/parameter conventions there. Reconcile
// against agent-habilis-mesh/include/mesh.h once Chunk A lands; the linker
// gate at integration will catch any mismatch.
#+build darwin
package main

import "core:c"
import "core:strings"

foreign import mesh_ffi {
	"../agent-habilis-mesh/lib/libagent_habilis_mesh_ffi.a",
	"system:Security.framework",
	"system:SystemConfiguration.framework",
	"system:CoreWLAN.framework",
	"system:SecurityFoundation.framework",
	"system:Foundation.framework",
	"system:CoreFoundation.framework",
	"system:objc",
	"system:iconv",
}

// Opaque handle to an open mesh pipe.
Mesh_Pipe :: struct {}

Mesh_Opts :: struct {
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

Mesh_Frame :: struct {
	nick:     [64]u8,
	directed: c.int,
	eof:      c.int,
	len:      c.size_t,
}

@(default_calling_convention = "c")
foreign mesh_ffi {
	mesh_open :: proc(opts: ^Mesh_Opts) -> ^Mesh_Pipe ---
	mesh_id :: proc(h: ^Mesh_Pipe) -> cstring ---
	mesh_name :: proc(h: ^Mesh_Pipe) -> cstring ---
	mesh_nickname :: proc(h: ^Mesh_Pipe) -> cstring ---
	// recv one frame into buf (cap bytes); timeout_ms=0 always (never block the
	// render loop). Returns 1 (frame ready, frame.len says how many bytes of buf
	// are valid), 0 (nothing pending), or -1 (error, see mesh_last_error).
	mesh_recv :: proc(h: ^Mesh_Pipe, buf: [^]u8, cap: c.size_t, timeout_ms: c.int, frame: ^Mesh_Frame) -> c.long ---
	// to == nil broadcasts; otherwise a directed send to that nickname.
	mesh_send :: proc(h: ^Mesh_Pipe, to: cstring, buf: [^]u8, len: c.size_t) -> c.long ---
	mesh_send_eof :: proc(h: ^Mesh_Pipe, to: cstring) -> c.long ---
	// Needed-length protocol: buf == nil (cap ignored) returns the required
	// buffer size; call again with a big-enough buffer to fill it.
	mesh_peers_json :: proc(h: ^Mesh_Pipe, buf: [^]u8, cap: c.size_t) -> c.long ---
	mesh_state_json :: proc(h: ^Mesh_Pipe, buf: [^]u8, cap: c.size_t) -> c.long ---
	mesh_state_merge :: proc(h: ^Mesh_Pipe, merge_json: cstring) -> c.long ---
	mesh_peer_count :: proc(h: ^Mesh_Pipe) -> c.long ---
	mesh_max_chunk :: proc(h: ^Mesh_Pipe) -> c.size_t ---
	mesh_close :: proc(h: ^Mesh_Pipe) ---
	// No handle: must be callable when mesh_open itself failed.
	mesh_last_error :: proc() -> cstring ---
	mesh_version :: proc() -> cstring ---
}

// Fill `buf` via the needed-length protocol shared by mesh_peers_json and
// mesh_state_json: probe for the required size, allocate, fill. Returns ""
// on error or an empty document.
//
// The FFI's copy_out NUL-terminates and only writes when `needed < cap`, so
// the buffer must be one byte larger than the reported length — same as the
// Rust smoke test (`needed + 1`). A buffer of exactly `needed` leaves the
// contents untouched (zeros here), which then fails JSON parse and looks
// like an empty roster forever.
@(private = "file")
mesh_sized_json :: proc(
	h: ^Mesh_Pipe,
	fn: proc "c" (h: ^Mesh_Pipe, buf: [^]u8, cap: c.size_t) -> c.long,
	allocator := context.temp_allocator,
) -> string {
	needed := fn(h, nil, 0)
	if needed <= 0 {
		return ""
	}
	buf := make([]u8, int(needed) + 1, allocator)
	n := fn(h, raw_data(buf), c.size_t(len(buf)))
	if n <= 0 {
		return ""
	}
	return string(buf[:n])
}

mesh_peers_json_string :: proc(h: ^Mesh_Pipe, allocator := context.temp_allocator) -> string {
	return mesh_sized_json(h, mesh_peers_json, allocator)
}

mesh_state_json_string :: proc(h: ^Mesh_Pipe, allocator := context.temp_allocator) -> string {
	return mesh_sized_json(h, mesh_state_json, allocator)
}

// Clone a borrowed cstring (valid only for the handle's lifetime) into an
// owned Odin string. Returns "" for a nil cstring.
mesh_clone_cstring :: proc(s: cstring, allocator := context.allocator) -> string {
	if s == nil {
		return ""
	}
	out, _ := strings.clone_from_cstring(s, allocator)
	return out
}

mesh_last_error_string :: proc() -> string {
	return mesh_clone_cstring(mesh_last_error(), context.temp_allocator)
}
