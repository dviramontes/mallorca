// Room lifecycle for mallorca's p2p mode: state machine on top of the
// fofoca binding (fofoca_ffi.odin). Replaces net.odin's Phoenix
// host/client with serverless snapshot streaming — see the design plan
// ("Key design decisions", "Phase 4") for the snapshot-not-replay rationale.
package p2p

import orca "../core"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

Status :: enum {
	Offline,
	Alone,
	Connected,
}

// A remote peer's grid: display-only, never ticked locally (see the plan's
// "snapshot streaming, not edit replay" decision). Same fields as the old
// Host_Sim minus its per-tick events buffer.
Peer_Sim :: struct {
	grid:      orca.Grid,
	marks:     []orca.Mark,
	seqs:      []u64, // per-cell user-edit generation; 0 = never user-touched
	tick:      uint,
	name:      string,
	tint:      int, // REMOTE_TINTS index from hash(name); for draw color only
	view_id:   int, // unique join-order id for ` view cycling (not color)
	announced: bool, // greeted once (backfill + join notice); apply & roster share it
}

// One sparse ink entry on the wire: cell coords + that peer's edit seq.
Ink_Cell :: struct {
	x: int,
	y: int,
	s: u64,
}

// Tint sentinel from jam_pick: negative means the local peer won the cell.
JAM_LOCAL :: -1

// One remote candidate for jam LWW compose (tests + draw).
Jam_Remote_Cell :: struct {
	glyph: u8,
	seq:   u64,
	tint:  int,
}

// Flags parsed from argv, consumed by open.
Cli_Opts :: struct {
	join_hash: string, // "" => create a new room
	room_name: string,
	nick:      string,
	private:   bool,
	no_mdns:   bool,
	no_dht:    bool,
	no_relay:  bool,
	max_peers: int,
}

State :: struct {
	pipe:                ^Pipe,
	// Owns every FFI call once open; see worker.odin. nil until open
	// succeeds, so a single-player session spawns no thread and no queues.
	worker:              ^Worker,
	room_name:           string,
	hash:                string,
	nick:                string,
	sims:                map[string]^Peer_Sim,
	next_view_id:        int, // monotonic; assigned to each new Peer_Sim.view_id
	rx:                  map[string]^[dynamic]u8, // per-nick partial-line buffer
	rx_batch:            [dynamic]Inbound, // reused drain buffer for poll
	roster_gen:          u64, // last Roster_Snapshot generation reconciled
	peer_count:          int,
	status:              Status,
	join_mode:           bool, // opened via --join-room (drives the alone hint)
	warned_collision:    bool, // own nickname seen in the roster (warn once)
	alone_elapsed:       f32, // join-mode seconds spent with 0 peers
	alone_hint_shown:    bool,
	last_synced_bpm:     int, // last bpm value reconciled with the shared doc (ours or adopted)
	last_synced_playing: bool,
}

// Shared transport state merged into the mesh's CRDT doc so every peer's bpm
// and play/pause follow the same clock (Phase 5, optional shared transport).
Transport_Msg :: struct {
	bpm:     int,
	playing: bool,
}

// Wire message for the one message type this protocol carries. Field names
// match the JSON keys directly (no tag renaming), same convention net.odin
// used for its snapshot message.
Snapshot_Msg :: struct {
	t:    string,
	w:    int,
	h:    int,
	grid: string,
	tick: uint,
	ink:  []Ink_Cell, // sparse user-edit seqs (seq > 0); omitted by old peers
}

// Build Opts from cli, open the pipe (create when join_hash == ""), and
// on success print the room line + bare hash + join hint to stdout (per the
// plan's Phase 4 open bullet).
//
// open is the one blocking FFI call left on the render thread: it stands
// up the endpoint and discovery, and main.odin runs it before the window opens
// precisely so the stall is invisible. Everything after it goes through the
// worker spawned at the end of this proc.
start :: proc(cli: Cli_Opts) -> (st: State, ok: bool) {
	st.sims = make(map[string]^Peer_Sim)
	st.rx = make(map[string]^[dynamic]u8)
	st.status = .Alone
	st.join_mode = cli.join_hash != ""

	fofoca_cstr: cstring = nil
	if cli.join_hash != "" {
		fofoca_cstr = strings.clone_to_cstring(cli.join_hash, context.temp_allocator)
	}
	name_cstr: cstring = nil
	if cli.room_name != "" {
		name_cstr = strings.clone_to_cstring(cli.room_name, context.temp_allocator)
	}
	nick_cstr := strings.clone_to_cstring(cli.nick, context.temp_allocator)

	opts := Opts {
		mesh      = fofoca_cstr,
		topic     = nil,
		nick      = nick_cstr,
		name      = name_cstr,
		is_public = 0 if cli.private else 1,
		mdns      = 0 if cli.no_mdns else 1,
		dht       = 0 if cli.no_dht else 1,
		relay     = 0 if cli.no_relay else 1,
		max_peers = c.size_t(cli.max_peers),
	}

	pipe := open(&opts)
	if pipe == nil {
		delete(st.sims)
		delete(st.rx)
		return {}, false
	}
	st.pipe = pipe
	// Borrowed accessors on the Rust handle — plain field reads, no event-loop
	// round trip. Cloned here while we still own the pipe exclusively; after
	// worker_start only the worker may touch it.
	st.hash = clone_cstring(id(pipe))
	st.room_name = clone_cstring(name(pipe))
	st.nick = clone_cstring(nickname(pipe))
	st.rx_batch = make([dynamic]Inbound, 0, 32)
	st.worker = worker_start(pipe)

	fmt.printfln("mallorca: room %q open  (%s)", st.room_name, st.nick)
	fmt.println(st.hash)
	fmt.printfln("mallorca: join with: mallorca --join-room=%s", st.hash)
	if cli.max_peers == 0 {
		fmt.printfln("mallorca: max peers: %d (default)", DEFAULT_MAX_PEERS)
	} else {
		fmt.printfln("mallorca: max peers: %d", cli.max_peers)
	}

	return st, true
}

// Take everything the worker has received since last frame, guard against our
// own echo, accumulate per-nick bytes, and apply each newline-delimited JSON
// line as it completes.
//
// The FFI is no longer touched here — the worker already did the blocking
// recv. What remains is pure CPU on the render thread, which is what lets
// apply keep mutating sims with no locking.
poll :: proc(st: ^State) {
	if st.worker == nil {
		return
	}
	worker_drain_inbox(st.worker, &st.rx_batch)
	for f in st.rx_batch {
		defer inbound_destroy(f)
		if f.nick == st.nick || f.eof {
			continue
		}
		feed(st, f.nick, f.bytes)
	}
	clear(&st.rx_batch)
}

// Append one frame's bytes to that peer's partial-line buffer and apply every
// complete line. Split out from poll so tests can drive it without a mesh.
feed :: proc(st: ^State, nick: string, bytes: []u8) {
	rxbuf, has := st.rx[nick]
	if !has {
		rxbuf = new([dynamic]u8)
		st.rx[strings.clone(nick)] = rxbuf
	}
	append(rxbuf, ..bytes)
	for {
		idx := index_byte(rxbuf[:], '\n')
		if idx < 0 {
			break
		}
		apply(st, nick, string(rxbuf[:idx]))
		remaining := len(rxbuf) - (idx + 1)
		copy(rxbuf[:remaining], rxbuf[idx + 1:])
		resize(rxbuf, remaining)
	}
}

// Apply one decoded snapshot line: lazily create the sender's sim on first
// contact, realloc on a dimension change, copy cells, apply sparse ink seqs,
// and recompute display marks. Any t other than "snapshot" is dropped.
@(private = "file")
apply :: proc(st: ^State, nick: string, line: string) {
	msg: Snapshot_Msg
	if json.unmarshal(transmute([]u8)line, &msg, allocator = context.temp_allocator) != nil {
		return
	}
	if msg.t != "snapshot" || msg.w <= 0 || msg.h <= 0 {
		return
	}

	sim, found := st.sims[nick]
	if !found {
		sim = new_sim(st, nick, msg.w, msg.h)
		st.sims[strings.clone(nick)] = sim
	} else if sim.grid.width != msg.w || sim.grid.height != msg.h {
		orca.destroy_grid(&sim.grid)
		sim.grid = orca.make_grid(msg.w, msg.h)
		delete(sim.marks)
		sim.marks = orca.make_marks(sim.grid)
		delete(sim.seqs)
		sim.seqs = make([]u64, msg.w * msg.h)
	}

	n := min(len(sim.grid.cells), len(msg.grid))
	copy(sim.grid.cells[:n], transmute([]u8)msg.grid[:n])
	sim.tick = msg.tick
	apply_ink(sim, msg.ink)
	orca.preview_marks(sim.grid, sim.marks, sim.tick, 0)
}

// Reset peer seqs from a full sparse ink list (every seq > 0 on the sender).
// Cells absent from ink become 0.
apply_ink :: proc(sim: ^Peer_Sim, ink: []Ink_Cell) {
	for &s in sim.seqs {
		s = 0
	}
	w := sim.grid.width
	h := sim.grid.height
	for cell in ink {
		if cell.x < 0 || cell.y < 0 || cell.x >= w || cell.y >= h {
			continue
		}
		sim.seqs[cell.y * w + cell.x] = cell.s
	}
}

// Sparse list of every cell with seq > 0 (full set each snapshot / backfill).
ink_from_seqs :: proc(
	seqs: []u64,
	width: int,
	height: int,
	allocator := context.temp_allocator,
) -> []Ink_Cell {
	if width <= 0 || height <= 0 || len(seqs) < width * height {
		return nil
	}
	ink := make([dynamic]Ink_Cell, 0, 16, allocator)
	for y in 0 ..< height {
		for x in 0 ..< width {
			s := seqs[y * width + x]
			if s > 0 {
				append(&ink, Ink_Cell{x = x, y = y, s = s})
			}
		}
	}
	return ink[:]
}

// Jam LWW: max user-edit seq wins (including clear / '.'). When every seq is
// 0, local non-empty wins, else the first non-empty remote in `remotes` order.
// The caller passes them in a stable order (ascending view_id, i.e. join order)
// so the seq-0 fallback picks a deterministic, flicker-free winner.
jam_pick :: proc(
	local_glyph: u8,
	local_seq: u64,
	remotes: []Jam_Remote_Cell,
) -> (
	glyph: u8,
	tint: int,
) {
	best_seq: u64 = 0
	best_glyph := local_glyph
	best_tint := JAM_LOCAL
	any_claim := local_seq > 0
	if local_seq > 0 {
		best_seq = local_seq
	}
	for r in remotes {
		if r.seq > 0 {
			any_claim = true
			if r.seq > best_seq {
				best_seq = r.seq
				best_glyph = r.glyph
				best_tint = r.tint
			}
		}
	}
	if any_claim {
		return best_glyph, best_tint
	}
	// No user claims: legacy jam overlay — local glyph, else remotes in order.
	if local_glyph != orca.EMPTY_GLYPH {
		return local_glyph, JAM_LOCAL
	}
	for r in remotes {
		if r.glyph != orca.EMPTY_GLYPH {
			return r.glyph, r.tint
		}
	}
	return orca.EMPTY_GLYPH, JAM_LOCAL
}

// Broadcast our own grid. Skipped when nobody is in the room.
send_own :: proc(st: ^State, grid: orca.Grid, tick: uint, seqs: []u64) {
	if st.peer_count == 0 {
		return
	}
	send_snapshot(st, "", grid, tick, seqs)
}

// Directed send to one nick — used for backfill snapshots to a peer that just
// joined (mesh frames aren't retained, so a fresh peer has seen nothing yet).
send_own_to :: proc(st: ^State, to: string, grid: orca.Grid, tick: uint, seqs: []u64) {
	send_snapshot(st, to, grid, tick, seqs)
}

// Marshal the grid into one newline-terminated wire line. The result is
// heap-owned, never temp: it is handed to the mesh worker, which may not
// consume it until after the render thread has already reset its temp arena.
// Returns nil when the snapshot can't be marshalled.
@(private = "file")
build_snapshot :: proc(grid: orca.Grid, tick: uint, seqs: []u64) -> []u8 {
	snap := Snapshot_Msg {
		t    = "snapshot",
		w    = grid.width,
		h    = grid.height,
		grid = string(grid.cells),
		tick = tick,
		ink  = ink_from_seqs(seqs, grid.width, grid.height),
	}
	// json.marshal, never fmt: fmt treats '{' as a directive and mangles JSON.
	data, err := json.marshal(snap, allocator = context.temp_allocator)
	if err != nil {
		return nil
	}
	line := make([]u8, len(data) + 1)
	copy(line, data)
	line[len(data)] = '\n'
	return line
}

// `to == ""` broadcasts; otherwise a directed send to that nickname. Hands the
// line to the worker rather than sending it here — send blocks until the
// engine has actually gossiped the frame.
@(private = "file")
send_snapshot :: proc(st: ^State, to: string, grid: orca.Grid, tick: uint, seqs: []u64) {
	if st.worker == nil {
		return
	}
	line := build_snapshot(grid, tick, seqs)
	if line == nil {
		return
	}
	worker_enqueue(st.worker, Send_Req{to = strings.clone(to), payload = line})
}

// Push our own bpm/playing into the shared CRDT doc. No-op when the room isn't
// open. Records what we pushed so the roster tick's adopt-side doesn't turn
// around and treat our own merge as a remote change (feedback loop).
share_transport :: proc(st: ^State, bpm: int, playing: bool) {
	if st.worker == nil {
		return
	}
	st.last_synced_bpm = bpm
	st.last_synced_playing = playing
	merge := build_transport_merge(bpm, playing)
	if merge == "" {
		return
	}
	worker_enqueue(st.worker, Merge_Req{json = merge})
}

// Marshal bpm/playing into an RFC 7386 merge document. Heap-owned for the same
// reason as build_snapshot. Returns "" when marshalling fails.
@(private = "file")
build_transport_merge :: proc(bpm: int, playing: bool) -> string {
	msg := Transport_Msg {
		bpm     = bpm,
		playing = playing,
	}
	// json.marshal, never fmt: fmt treats '{' as a directive and mangles JSON.
	data, err := json.marshal(msg, allocator = context.temp_allocator)
	if err != nil {
		return ""
	}
	return strings.clone(string(data))
}

// Shape of peers_json — the agent-gossip `peers` document, not a bare
// string array. Only `nickname` is consumed; other RosterEntry fields are
// ignored by the unmarshaler.
@(private = "file")
Fofoca_Roster_Entry :: struct {
	nickname: string,
}

@(private = "file")
Fofoca_Roster :: struct {
	peers: []Fofoca_Roster_Entry,
}

// Extract peer nicknames from a peers_json document.
// ok=false on empty input or parse failure — callers must not treat that as
// "everyone left" when peer_count still reports peers.
parse_roster_nicks :: proc(
	peers_json: string,
	allocator := context.temp_allocator,
) -> (
	nicks: []string,
	ok: bool,
) {
	if peers_json == "" {
		return nil, false
	}
	roster: Fofoca_Roster
	if json.unmarshal(transmute([]u8)peers_json, &roster, allocator = allocator) != nil {
		return nil, false
	}
	nicks = make([]string, len(roster.peers), allocator)
	for entry, i in roster.peers {
		nicks[i] = entry.nickname
	}
	return nicks, true
}

// What one roster tick wants the host to do. The reconciliation itself is
// pure mesh bookkeeping, but its outcomes are all host concerns — a status
// line, the transport clock, silencing sustained notes — so they are returned
// rather than applied. That is what keeps this package free of `App` and
// therefore importable by it.
//
// `statuses` are in the order they occurred and are owned by the caller's
// allocator; a host that only shows the newest can take the last.
Roster_Result :: struct {
	statuses:    []string,
	bpm:         Maybe(int), // adopt this bpm from the shared doc
	playing:     Maybe(bool), // adopt this play state from the shared doc
	flush_notes: bool, // remote paused us: silence sustained notes
}

// Roster reconciliation: peer count -> status, peers_json diff -> join/leave
// sims (with directed backfill on join), own-nick collision warning, and (in
// join mode) the 15s-alone one-shot hint.
//
// The 1s cadence comes from the worker, which republishes the roster once per
// ROSTER_PERIOD and bumps a generation. Reconciling on a generation change
// rather than a local timer keeps the old "exactly once per fresh read"
// semantics — including alone_elapsed's assumption that this body runs about
// once a second — without the render thread ever calling the FFI.
roster_tick :: proc(
	st: ^State,
	grid: orca.Grid,
	tick: uint,
	edit_seqs: []u64,
	bpm: int,
	playing: bool,
	bpm_min: int,
	bpm_max: int,
	allocator := context.temp_allocator,
) -> (
	res: Roster_Result,
) {
	// Assign res.statuses at each return, not via `defer`: a deferred
	// assignment to a named return is dropped (the return copy is taken
	// before defers run), which silently ate every status line before.
	out := make([dynamic]string, allocator)

	if st.worker == nil {
		res.statuses = out[:]
		return
	}

	// Surface anything the worker failed at. last_error is thread_local on the
	// Rust side, so the worker captured the message for us; calling
	// last_error_string() here would read our own empty slot.
	if msg := worker_take_error(st.worker); msg != "" {
		defer delete(msg)
		append(&out, fmt.aprintf("mesh: %s", msg, allocator = allocator))
	}

	snap, fresh := worker_take_roster(st.worker, st.roster_gen)
	if !fresh {
		res.statuses = out[:]
		return
	}
	defer delete(snap.peers_json)
	defer delete(snap.state_json)
	st.roster_gen = snap.generation

	st.peer_count = snap.peer_count
	st.status = .Connected if st.peer_count > 0 else .Alone

	peers, roster_ok := parse_roster_nicks(snap.peers_json, context.temp_allocator)
	// A missing/unreadable roster must not wipe sims while the mesh still
	// reports peers (grow-during-read used to yield a zeroed buffer → empty
	// parse → every remote "left"). Skip join/leave reconciliation that tick.
	roster_usable := roster_ok && !(len(peers) == 0 && st.peer_count > 0)
	if roster_usable {
		seen := make(map[string]bool, allocator = context.temp_allocator)
		collision := false
		for nick in peers {
			if nick == st.nick {
				collision = true
				continue
			}
			seen[nick] = true
			// apply() may have created the sim from a snapshot that beat this
			// roster read; announced greets exactly once either way. Backfill
			// matters because the mesh keeps no history — a paused host would
			// otherwise never send the newcomer its grid.
			sim, exists := st.sims[nick]
			if !exists {
				sim = new_sim(st, nick, grid.width, grid.height)
				st.sims[strings.clone(nick)] = sim
			}
			if !sim.announced {
				sim.announced = true
				send_own_to(st, nick, grid, tick, edit_seqs)
				append(&out, fmt.aprintf("%s joined", nick, allocator = allocator))
			}
		}

		gone := make([dynamic]string, context.temp_allocator)
		for nick in st.sims {
			if nick not_in seen {
				append(&gone, nick)
			}
		}
		for nick in gone {
			sim := st.sims[nick]
			free_sim(sim)
			// Free what the maps cloned, or every departure leaks a key and the
			// rx buffer. `nick` aliases the sims key, so free dk last (after the
			// last read of nick); rk is feed's separate clone of the rx key.
			if rk, rbuf := delete_key(&st.rx, nick); rbuf != nil {
				delete(rbuf^)
				free(rbuf)
				delete(rk)
			}
			dk, _ := delete_key(&st.sims, nick)
			append(&out, fmt.aprintf("%s left", nick, allocator = allocator))
			delete(dk)
		}

		if collision && !st.warned_collision {
			st.warned_collision = true
			append(
				&out,
				fmt.aprintf(
					"warning: nickname %s already in use in this room",
					st.nick,
					allocator = allocator,
				),
			)
		}
	}

	if st.join_mode && !st.alone_hint_shown {
		if st.peer_count == 0 {
			st.alone_elapsed += 1.0 // this block runs once per second
			if st.alone_elapsed >= 15.0 {
				st.alone_hint_shown = true
				append(
					&out,
					fmt.aprintf("no peers yet — check the room id", allocator = allocator),
				)
			}
		} else {
			st.alone_elapsed = 0
		}
	}

	// Adopt shared transport state (bpm/playing) from the doc. Only react to
	// values that differ both from our current local state and from what we
	// last reconciled (ours or previously adopted) — a value we already know
	// about is either unchanged or the echo of our own last merge, not a new
	// remote change.
	state_json := snap.state_json
	if state_json != "" {
		remote: Transport_Msg
		if json.unmarshal(
			   transmute([]u8)state_json,
			   &remote,
			   allocator = context.temp_allocator,
		   ) ==
		   nil {
			// Ignore an out-of-range shared bpm: this side never re-clamps what
			// it adopts, so a bad peer could otherwise push everyone past BPM_MAX.
			in_range := remote.bpm >= bpm_min && remote.bpm <= bpm_max
			if in_range && remote.bpm != bpm && remote.bpm != st.last_synced_bpm {
				st.last_synced_bpm = remote.bpm
				res.bpm = remote.bpm
				append(&out, fmt.aprintf("bpm synced to %d", remote.bpm, allocator = allocator))
			}
			if remote.playing != playing && remote.playing != st.last_synced_playing {
				st.last_synced_playing = remote.playing
				res.playing = remote.playing
				res.flush_notes = !remote.playing
				append(
					&out,
					fmt.aprintf(
						"%s (synced)",
						"playing" if remote.playing else "paused",
						allocator = allocator,
					),
				)
			}
		}
	}
	res.statuses = out[:]
	return
}

// Number of distinct peer tints. The palette itself is the host's business
// (`REMOTE_TINTS` in main.odin, which asserts its length against this); this
// package only needs the modulus to hash a nickname into it.
TINT_COUNT :: 6

// FNV-1a over the nickname → stable index into the host's tint palette.
tint_from_name :: proc(name: string) -> int {
	h: u64 = 14695981039346656037
	for b in transmute([]u8)name {
		h ~= u64(b)
		h *= 1099511628211
	}
	return int(h % u64(TINT_COUNT))
}

@(private = "file")
new_sim :: proc(st: ^State, nick: string, w, h: int) -> ^Peer_Sim {
	sim := new(Peer_Sim)
	sim.grid = orca.make_grid(w, h)
	sim.marks = orca.make_marks(sim.grid)
	sim.seqs = make([]u64, w * h)
	sim.name = strings.clone(nick)
	sim.tint = tint_from_name(nick)
	sim.view_id = st.next_view_id
	st.next_view_id += 1
	return sim
}

@(private = "file")
free_sim :: proc(sim: ^Peer_Sim) {
	orca.destroy_grid(&sim.grid)
	delete(sim.marks)
	delete(sim.seqs)
	delete(sim.name)
	free(sim)
}

shutdown :: proc(st: ^State) {
	// Stop the worker first: it must be joined before anything frees the
	// queues it writes into, and before close consumes the pipe it holds.
	worker_stop(st.worker)
	st.worker = nil
	for f in st.rx_batch {
		inbound_destroy(f)
	}
	delete(st.rx_batch)

	// Free the cloned keys with their values; the maps are torn down next.
	for nick, sim in st.sims {
		free_sim(sim)
		delete(nick)
	}
	delete(st.sims)
	for nick, buf in st.rx {
		delete(buf^)
		free(buf)
		delete(nick)
	}
	delete(st.rx)
	delete(st.room_name)
	delete(st.hash)
	delete(st.nick)
	if st.pipe != nil {
		// Blocks for DEPARTURE_GRACE (750ms) on the Rust side. Harmless here:
		// defers run LIFO, so k2.shutdown() has already torn the window down
		// by the time main.odin reaches this.
		close(st.pipe)
	}
	st^ = {}
}

@(private = "file")
index_byte :: proc(s: []u8, b: u8) -> int {
	for v, i in s {
		if v == b {
			return i
		}
	}
	return -1
}
