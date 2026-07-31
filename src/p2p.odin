// Room lifecycle for mallorca's p2p mode: state machine on top of the
// agent-habilis-mesh binding (mesh.odin). Replaces net.odin's Phoenix
// host/client with serverless snapshot streaming — see the design plan
// ("Key design decisions", "Phase 4") for the snapshot-not-replay rationale.
package main

import orca "core"
import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:strings"

P2p_Status :: enum {
	Offline,
	Alone,
	Connected,
}

// A remote peer's grid: display-only, never ticked locally (see the plan's
// "snapshot streaming, not edit replay" decision). Same fields as the old
// Host_Sim minus its per-tick events buffer.
Peer_Sim :: struct {
	grid:  orca.Grid,
	marks: []orca.Mark,
	tick:  uint,
	name:  string,
	tint:  int,
}

// Flags parsed from argv, consumed by p2p_open.
P2p_Cli_Opts :: struct {
	join_hash: string, // "" => create a new room
	room_name: string,
	nick:      string,
	private:   bool,
	no_mdns:   bool,
	no_dht:    bool,
	no_relay:  bool,
	max_peers: int,
}

P2p_State :: struct {
	pipe:              ^Mesh_Pipe,
	room_name:         string,
	hash:              string,
	nick:              string,
	sims:              map[string]^Peer_Sim,
	next_tint:         int,
	rx:                map[string]^[dynamic]u8, // per-nick partial-line buffer
	roster_timer:      f32, // accumulates toward the 1s roster-poll cadence
	peer_count:        int,
	status:            P2p_Status,
	join_mode:         bool, // opened via --join-room (drives the alone hint)
	warned_collision:  bool, // own nickname seen in the roster (warn once)
	alone_elapsed:     f32, // join-mode seconds spent with 0 peers
	alone_hint_shown:  bool,
	last_synced_bpm:      int, // last bpm value reconciled with the shared doc (ours or adopted)
	last_synced_playing:  bool,
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
}

// Build Mesh_Opts from cli, open the pipe (create when join_hash == ""), and
// on success print the room line + bare hash + join hint to stdout (per the
// plan's Phase 4 p2p_open bullet). All mesh calls are main-thread / timeout=0.
p2p_open :: proc(cli: P2p_Cli_Opts) -> (st: P2p_State, ok: bool) {
	st.sims = make(map[string]^Peer_Sim)
	st.rx = make(map[string]^[dynamic]u8)
	st.status = .Alone
	st.join_mode = cli.join_hash != ""

	mesh_cstr: cstring = nil
	if cli.join_hash != "" {
		mesh_cstr = strings.clone_to_cstring(cli.join_hash, context.temp_allocator)
	}
	name_cstr: cstring = nil
	if cli.room_name != "" {
		name_cstr = strings.clone_to_cstring(cli.room_name, context.temp_allocator)
	}
	nick_cstr := strings.clone_to_cstring(cli.nick, context.temp_allocator)

	opts := Mesh_Opts {
		mesh      = mesh_cstr,
		topic     = nil,
		nick      = nick_cstr,
		name      = name_cstr,
		is_public = 0 if cli.private else 1,
		mdns      = 0 if cli.no_mdns else 1,
		dht       = 0 if cli.no_dht else 1,
		relay     = 0 if cli.no_relay else 1,
		max_peers = c.size_t(cli.max_peers),
	}

	pipe := mesh_open(&opts)
	if pipe == nil {
		delete(st.sims)
		delete(st.rx)
		return {}, false
	}
	st.pipe = pipe
	st.hash = mesh_clone_cstring(mesh_id(pipe))
	st.room_name = mesh_clone_cstring(mesh_name(pipe))
	st.nick = mesh_clone_cstring(mesh_nickname(pipe))

	fmt.printfln("mallorca: room %q open  (%s)", st.room_name, st.nick)
	fmt.println(st.hash)
	fmt.printfln("mallorca: join with: mallorca --join-room=%s", st.hash)

	return st, true
}

P2P_RECV_BUF :: 65536

// Drain every pending frame (0ms timeout, non-blocking), guard against our
// own echo, accumulate per-nick bytes, and apply each newline-delimited JSON
// line as it completes.
p2p_poll :: proc(st: ^P2p_State) {
	buf: [P2P_RECV_BUF]u8
	for {
		frame: Mesh_Frame
		n := mesh_recv(st.pipe, &buf[0], c.size_t(len(buf)), 0, &frame)
		if n <= 0 {
			break
		}
		nick := p2p_frame_nick(&frame)
		if nick == st.nick || frame.eof != 0 {
			continue
		}
		flen := min(int(frame.len), len(buf))

		rxbuf, has := st.rx[nick]
		if !has {
			rxbuf = new([dynamic]u8)
			st.rx[strings.clone(nick)] = rxbuf
		}
		append(rxbuf, ..buf[:flen])
		for {
			idx := p2p_index_byte(rxbuf[:], '\n')
			if idx < 0 {
				break
			}
			p2p_apply(st, nick, string(rxbuf[:idx]))
			remaining := len(rxbuf) - (idx + 1)
			copy(rxbuf[:remaining], rxbuf[idx + 1:])
			resize(rxbuf, remaining)
		}
	}
}

// Apply one decoded snapshot line: lazily create the sender's sim on first
// contact (join-order tint), realloc on a dimension change, copy cells, and
// recompute display marks. Any t other than "snapshot" is dropped.
@(private = "file")
p2p_apply :: proc(st: ^P2p_State, nick: string, line: string) {
	msg: Snapshot_Msg
	if json.unmarshal(transmute([]u8)line, &msg, allocator = context.temp_allocator) != nil {
		return
	}
	if msg.t != "snapshot" || msg.w <= 0 || msg.h <= 0 {
		return
	}

	sim, found := st.sims[nick]
	if !found {
		sim = new(Peer_Sim)
		sim.grid = orca.make_grid(msg.w, msg.h)
		sim.marks = orca.make_marks(sim.grid)
		sim.name = strings.clone(nick)
		sim.tint = st.next_tint
		st.next_tint += 1
		st.sims[strings.clone(nick)] = sim
	} else if sim.grid.width != msg.w || sim.grid.height != msg.h {
		orca.destroy_grid(&sim.grid)
		sim.grid = orca.make_grid(msg.w, msg.h)
		delete(sim.marks)
		sim.marks = orca.make_marks(sim.grid)
	}

	n := min(len(sim.grid.cells), len(msg.grid))
	copy(sim.grid.cells[:n], transmute([]u8)msg.grid[:n])
	sim.tick = msg.tick
	orca.preview_marks(sim.grid, sim.marks, sim.tick, 0)
}

// Broadcast our own grid. Skipped when nobody is in the room.
p2p_send_own :: proc(st: ^P2p_State, grid: orca.Grid, tick: uint) {
	if st.peer_count == 0 {
		return
	}
	p2p_send_snapshot(st, nil, grid, tick)
}

// Directed send to one nick — used for backfill snapshots to a peer that just
// joined (mesh frames aren't retained, so a fresh peer has seen nothing yet).
p2p_send_own_to :: proc(st: ^P2p_State, to: string, grid: orca.Grid, tick: uint) {
	to_c := strings.clone_to_cstring(to, context.temp_allocator)
	p2p_send_snapshot(st, to_c, grid, tick)
}

@(private = "file")
p2p_send_snapshot :: proc(st: ^P2p_State, to: cstring, grid: orca.Grid, tick: uint) {
	snap := Snapshot_Msg {
		t    = "snapshot",
		w    = grid.width,
		h    = grid.height,
		grid = string(grid.cells),
		tick = tick,
	}
	// json.marshal, never fmt: fmt treats '{' as a directive and mangles JSON.
	data, err := json.marshal(snap, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	line := make([]u8, len(data) + 1, context.temp_allocator)
	copy(line, data)
	line[len(data)] = '\n'
	mesh_send(st.pipe, to, raw_data(line), c.size_t(len(line)))
}

// Push our own bpm/playing into the shared CRDT doc. No-op when the pipe
// isn't open. Records what we pushed so the roster tick's adopt-side doesn't
// turn around and treat our own merge as a remote change (feedback loop).
p2p_share_transport :: proc(st: ^P2p_State, bpm: int, playing: bool) {
	if st.pipe == nil {
		return
	}
	st.last_synced_bpm = bpm
	st.last_synced_playing = playing
	msg := Transport_Msg{bpm = bpm, playing = playing}
	// json.marshal, never fmt: fmt treats '{' as a directive and mangles JSON.
	data, err := json.marshal(msg, allocator = context.temp_allocator)
	if err != nil {
		return
	}
	cstr := strings.clone_to_cstring(string(data), context.temp_allocator)
	mesh_state_merge(st.pipe, cstr)
}

// Shape of mesh_peers_json — the agent-gossip `peers` document, not a bare
// string array. Only `nickname` is consumed; other RosterEntry fields are
// ignored by the unmarshaler.
@(private = "file")
Mesh_Roster_Entry :: struct {
	nickname: string,
}

@(private = "file")
Mesh_Roster :: struct {
	peers: []Mesh_Roster_Entry,
}

// Extract peer nicknames from a mesh_peers_json document. Returns nil on
// empty input or parse failure (callers treat that as "nobody else").
p2p_parse_roster_nicks :: proc(
	peers_json: string,
	allocator := context.temp_allocator,
) -> []string {
	if peers_json == "" {
		return nil
	}
	roster: Mesh_Roster
	if json.unmarshal(
		   transmute([]u8)peers_json,
		   &roster,
		   allocator = allocator,
	   ) !=
	   nil {
		return nil
	}
	nicks := make([]string, len(roster.peers), allocator)
	for entry, i in roster.peers {
		nicks[i] = entry.nickname
	}
	return nicks
}

// 1s-cadence roster reconciliation: peer count -> status, peers_json diff ->
// join/leave sims (with directed backfill on join), own-nick collision
// warning, and (in join mode) the 15s-alone one-shot hint. Takes the App
// directly since join/leave/collision/hint all report through set_status.
p2p_roster_tick :: proc(app: ^App, dt: f32) {
	st := &app.p2p
	st.roster_timer += dt
	if st.roster_timer < 1.0 {
		return
	}
	st.roster_timer -= 1.0

	st.peer_count = int(mesh_peer_count(st.pipe))
	st.status = .Connected if st.peer_count > 0 else .Alone

	peers := p2p_parse_roster_nicks(
		mesh_peers_json_string(st.pipe, context.temp_allocator),
		context.temp_allocator,
	)

	seen := make(map[string]bool, allocator = context.temp_allocator)
	collision := false
	for nick in peers {
		if nick == st.nick {
			collision = true
			continue
		}
		seen[nick] = true
		if nick not_in st.sims {
			sim := new(Peer_Sim)
			sim.grid = orca.make_grid(app.grid.width, app.grid.height)
			sim.marks = orca.make_marks(sim.grid)
			sim.name = strings.clone(nick)
			sim.tint = st.next_tint
			st.next_tint += 1
			st.sims[strings.clone(nick)] = sim
			p2p_send_own_to(st, nick, app.grid, app.tick)
			set_status(app, fmt.aprintf("%s joined", nick))
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
		p2p_free_sim(sim)
		delete_key(&st.sims, nick)
		set_status(app, fmt.aprintf("%s left", nick))
	}

	if collision && !st.warned_collision {
		st.warned_collision = true
		set_status(app, fmt.aprintf("warning: nickname %s already in use in this room", st.nick))
	}

	if st.join_mode && !st.alone_hint_shown {
		if st.peer_count == 0 {
			st.alone_elapsed += 1.0 // this block runs once per second
			if st.alone_elapsed >= 15.0 {
				st.alone_hint_shown = true
				set_status(app, fmt.aprintf("no peers yet — check the room id"))
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
	state_json := mesh_state_json_string(st.pipe, context.temp_allocator)
	if state_json != "" {
		remote: Transport_Msg
		if json.unmarshal(transmute([]u8)state_json, &remote, allocator = context.temp_allocator) == nil {
			if remote.bpm >= BPM_MIN &&
			   remote.bpm != app.bpm &&
			   remote.bpm != st.last_synced_bpm {
				app.bpm = remote.bpm
				st.last_synced_bpm = remote.bpm
				set_status(app, fmt.aprintf("bpm synced to %d", remote.bpm))
			}
			if remote.playing != app.playing && remote.playing != st.last_synced_playing {
				app.playing = remote.playing
				st.last_synced_playing = remote.playing
				if !app.playing {
					flush_notes(&app.midi, &app.sus)
				}
				set_status(app, fmt.aprintf("%s (synced)", "playing" if app.playing else "paused"))
			}
		}
	}
}

@(private = "file")
p2p_free_sim :: proc(sim: ^Peer_Sim) {
	orca.destroy_grid(&sim.grid)
	delete(sim.marks)
	delete(sim.name)
	free(sim)
}

p2p_shutdown :: proc(st: ^P2p_State) {
	for _, sim in st.sims {
		p2p_free_sim(sim)
	}
	delete(st.sims)
	for _, buf in st.rx {
		delete(buf^)
		free(buf)
	}
	delete(st.rx)
	delete(st.room_name)
	delete(st.hash)
	delete(st.nick)
	if st.pipe != nil {
		mesh_close(st.pipe)
	}
	st^ = {}
}

// The nickname a frame arrived from/for: nul-terminated within the fixed
// 64-byte field.
@(private = "file")
p2p_frame_nick :: proc(frame: ^Mesh_Frame) -> string {
	n := 0
	for n < len(frame.nick) && frame.nick[n] != 0 {
		n += 1
	}
	return string(frame.nick[:n])
}

@(private = "file")
p2p_index_byte :: proc(s: []u8, b: u8) -> int {
	for v, i in s {
		if v == b {
			return i
		}
	}
	return -1
}
