// Network client for mallorca's host <-> server link (PLAN.md M6).
// Line-delimited JSON over TCP; see docs/m6-network-protocol.md.
//
// M6 spike scope: dial, hello/welcome handshake, ping/pong round-trip. Later
// milestones build player lifecycle, edits, snapshots, and transport on top of
// the Net_Conn read/write primitives here.
package main

import orca "core"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"

NET_DEFAULT_PORT :: 4001

// A framed connection: the socket plus a buffer of bytes received but not yet
// split into a line (recv can return partial lines or several at once).
Net_Conn :: struct {
	sock: net.TCP_Socket,
	rbuf: [dynamic]u8,
}

net_dial :: proc(port: int = NET_DEFAULT_PORT) -> (conn: Net_Conn, ok: bool) {
	endpoint := net.Endpoint {
		address = net.IP4_Loopback,
		port    = port,
	}
	sock, err := net.dial_tcp(endpoint)
	if err != nil {
		fmt.eprintfln("net: dial 127.0.0.1:%d failed: %v", port, err)
		return {}, false
	}
	return Net_Conn{sock = sock}, true
}

net_close :: proc(c: ^Net_Conn) {
	net.close(c.sock)
	delete(c.rbuf)
}

// Send one JSON message as a single '\n'-terminated line.
net_send_line :: proc(c: ^Net_Conn, line: string) -> bool {
	framed := strings.concatenate({line, "\n"}, context.temp_allocator)
	data := transmute([]u8)framed
	for sent := 0; sent < len(data); {
		n, err := net.send_tcp(c.sock, data[sent:])
		if err != nil {
			fmt.eprintfln("net: send failed: %v", err)
			return false
		}
		sent += n
	}
	return true
}

// Read one line (without the trailing '\n'). The returned string is valid until
// the next call. Blocks until a full line arrives or the peer closes.
net_read_line :: proc(c: ^Net_Conn) -> (line: string, ok: bool) {
	for {
		if idx := index_byte(c.rbuf[:], '\n'); idx >= 0 {
			out := strings.clone(string(c.rbuf[:idx]), context.temp_allocator)
			consumed := idx + 1
			copy(c.rbuf[:], c.rbuf[consumed:]) // memmove-safe in Odin
			resize(&c.rbuf, len(c.rbuf) - consumed)
			return out, true
		}
		tmp: [4096]u8
		n, err := net.recv_tcp(c.sock, tmp[:])
		if err != nil || n == 0 {
			return "", false
		}
		append(&c.rbuf, ..tmp[:n])
	}
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

@(private = "file")
Welcome_Player :: struct {
	pid:  string,
	name: string,
}

// Send hello (optionally requesting a specific room) and parse the welcome;
// returns the room code and any players already present. Shared by the spike
// and host modes.
@(private = "file")
net_hello :: proc(
	c: ^Net_Conn,
	room := "",
) -> (
	assigned: string,
	players: []Welcome_Player,
	ok: bool,
) {
	// Build via concatenation, not fmt: Odin's fmt treats '{' as a directive and
	// would mangle the JSON braces.
	hello := `{"t":"hello","v":1,"role":"host","name":"mallorca-host"}`
	if room != "" {
		hello = strings.concatenate(
			{`{"t":"hello","v":1,"role":"host","name":"mallorca-host","room":"`, room, `"}`},
			context.temp_allocator,
		)
	}
	net_send_line(c, hello)
	wline, wok := net_read_line(c)
	if !wok {
		fmt.eprintln("net: no welcome (server closed?)")
		return "", nil, false
	}
	Welcome :: struct {
		room:    string,
		bpm:     int,
		playing: bool,
		players: []Welcome_Player,
	}
	w: Welcome
	if err := json.unmarshal(transmute([]u8)wline, &w); err != nil {
		fmt.eprintfln("net: bad welcome %q: %v", wline, err)
		return "", nil, false
	}
	fmt.printfln(
		"net: <- welcome  room=%s bpm=%d playing=%v players=%d",
		w.room,
		w.bpm,
		w.playing,
		len(w.players),
	)
	return w.room, w.players, true
}

// run_net_spike proves the Odin <-> Phoenix link end to end: dial, hello ->
// welcome, ping -> pong (with a round-trip time), then exit. Invoked with the
// `--net-spike` flag instead of opening the window.
run_net_spike :: proc() {
	fmt.printfln("net-spike: dialing 127.0.0.1:%d ...", NET_DEFAULT_PORT)
	c, ok := net_dial()
	if !ok {
		os.exit(1)
	}
	defer net_close(&c)

	if _, _, hok := net_hello(&c); !hok {
		os.exit(1)
	}

	// ping -> pong, timed locally
	start := time.tick_now()
	net_send_line(&c, `{"t":"ping","ts":1}`)
	pline, pok := net_read_line(&c)
	if !pok {
		fmt.eprintln("net-spike: no pong")
		os.exit(1)
	}
	rtt_ms := time.duration_milliseconds(time.tick_since(start))
	Pong :: struct {
		t: string,
	}
	p: Pong
	json.unmarshal(transmute([]u8)pline, &p)
	fmt.printfln("net-spike: <- %s  rtt=%.3fms", p.t, rtt_ms)

	fmt.println("net-spike: OK")
}

// Connection state for the host<->server link (drives the M9 indicator).
Net_Status :: enum {
	Disconnected,
	Connecting,
	Connected,
}

// A per-player simulation the host owns: its grid + marks + scratch events.
Host_Sim :: struct {
	grid:   orca.Grid,
	marks:  []orca.Mark,
	events: [dynamic]orca.Event,
	tick:   uint,
	name:   string, // player's display name, for the host's remote-view label
	tint:   int, // stable per-player color/order index (monotonic join order)
}

// Everything the host needs to run remote players: the connection, its room, a
// VM per player, and the link status. Shared by the headless host loop and the
// windowed app.
Host_State :: struct {
	conn:      Net_Conn,
	room:      string,
	sims:      map[string]^Host_Sim,
	status:    Net_Status,
	next_tint: int, // hands out a stable color/order index per joining player
}

// One flat message struct covering player_join / player_leave / edit / paste
// (json.unmarshal ignores absent fields).
@(private = "file")
Host_Msg :: struct {
	t:     string,
	pid:   string,
	name:  string,
	x:     int,
	y:     int,
	g:     string,
	cells: string, // paste: '\n'-separated rows
}

@(private = "file")
Poll_Status :: enum {
	Line,
	Empty,
	Closed,
}

// Non-blocking line read: a complete line if one is ready, Empty if not yet, or
// Closed if the peer went away. Requires the socket in non-blocking mode.
@(private = "file")
net_poll_line :: proc(c: ^Net_Conn) -> (line: string, status: Poll_Status) {
	for {
		if idx := index_byte(c.rbuf[:], '\n'); idx >= 0 {
			out := strings.clone(string(c.rbuf[:idx]), context.temp_allocator)
			consumed := idx + 1
			copy(c.rbuf[:], c.rbuf[consumed:])
			resize(&c.rbuf, len(c.rbuf) - consumed)
			return out, .Line
		}
		tmp: [4096]u8
		n, err := net.recv_tcp(c.sock, tmp[:])
		if err == .Would_Block || err == .Timeout {
			return "", .Empty
		}
		if err != nil || n == 0 {
			return "", .Closed
		}
		append(&c.rbuf, ..tmp[:n])
	}
}

// Build and send an evaluated-grid snapshot for one player.
@(private = "file")
host_send_snapshot :: proc(c: ^Net_Conn, pid: string, grid: orca.Grid, tick: uint) {
	Snapshot :: struct {
		t:    string,
		pid:  string,
		w:    int,
		h:    int,
		grid: string,
		tick: uint,
	}
	snap := Snapshot {
		t    = "snapshot",
		pid  = pid,
		w    = grid.width,
		h    = grid.height,
		grid = string(grid.cells),
		tick = tick,
	}
	if data, err := json.marshal(snap, allocator = context.temp_allocator); err == nil {
		net_send_line(c, string(data))
	}
}

@(private = "file")
host_free_sim :: proc(sim: ^Host_Sim) {
	orca.destroy_grid(&sim.grid)
	delete(sim.marks)
	delete(sim.events)
	delete(sim.name)
	free(sim)
}

// Dial the server and attach as the host of `want_room` (server-assigned if
// empty): performs the blocking hello/welcome, seeds a grid for players already
// present, and switches the socket to non-blocking for per-frame polling.
host_connect :: proc(want_room := "") -> (st: Host_State, ok: bool) {
	st.status = .Connecting
	c, dok := net_dial()
	if !dok {
		st.status = .Disconnected
		return st, false
	}
	st.conn = c

	assigned, players, hok := net_hello(&st.conn, want_room)
	if !hok {
		net_close(&st.conn)
		st.status = .Disconnected
		return st, false
	}
	st.room = assigned
	st.sims = make(map[string]^Host_Sim)

	// Seed players who were already in the room before we attached.
	for p in players {
		if p.pid != "" && p.pid not_in st.sims {
			sim := new(Host_Sim)
			sim.grid = orca.make_grid(DEFAULT_W, DEFAULT_H)
			sim.marks = orca.make_marks(sim.grid)
			sim.name = strings.clone(p.name)
			sim.tint = st.next_tint
			st.next_tint += 1
			st.sims[strings.clone(p.pid)] = sim
			host_send_snapshot(&st.conn, p.pid, sim.grid, sim.tick)
		}
	}

	net.set_blocking(st.conn.sock, false)
	st.status = .Connected
	return st, true
}

@(private = "file")
host_apply :: proc(st: ^Host_State, m: Host_Msg) {
	switch m.t {
	case "player_join":
		if m.pid != "" && m.pid not_in st.sims {
			sim := new(Host_Sim)
			sim.grid = orca.make_grid(DEFAULT_W, DEFAULT_H)
			sim.marks = orca.make_marks(sim.grid)
			sim.name = strings.clone(m.name)
			sim.tint = st.next_tint
			st.next_tint += 1
			st.sims[strings.clone(m.pid)] = sim
			host_send_snapshot(&st.conn, m.pid, sim.grid, sim.tick)
		}
	case "player_leave":
		if sim, found := st.sims[m.pid]; found {
			host_free_sim(sim)
			delete_key(&st.sims, m.pid)
		}
	case "edit":
		if sim, found := st.sims[m.pid]; found && len(m.g) > 0 {
			orca.grid_set(sim.grid, m.x, m.y, m.g[0])
			host_send_snapshot(&st.conn, m.pid, sim.grid, sim.tick) // echo even while paused
		}
	case "paste":
		if sim, found := st.sims[m.pid]; found {
			lines := strings.split(m.cells, "\n", context.temp_allocator)
			for line, dy in lines {
				for j in 0 ..< len(line) {
					orca.grid_set(sim.grid, m.x + j, m.y + dy, line[j])
				}
			}
			host_send_snapshot(&st.conn, m.pid, sim.grid, sim.tick)
		}
	}
}

// Drain and apply any pending messages (non-blocking). Returns false and flips
// to Disconnected if the peer went away; the caller should stop hosting.
host_poll :: proc(st: ^Host_State) -> (alive: bool) {
	if st.status != .Connected {
		return false
	}
	for {
		line, status := net_poll_line(&st.conn)
		switch status {
		case .Closed:
			st.status = .Disconnected
			return false
		case .Empty:
			return true
		case .Line:
			m: Host_Msg
			if json.unmarshal(transmute([]u8)line, &m, allocator = context.temp_allocator) == nil {
				host_apply(st, m)
			}
		}
	}
}

// Advance every remote player's grid one tick and stream it back. The caller
// runs advance_notes once per tick (shared with the host's own grid).
host_tick :: proc(st: ^Host_State, midi: ^Midi, sus: ^[dynamic]Sus_Note) {
	if st.status != .Connected {
		return
	}
	for pid, sim in st.sims {
		orca.run_tick(sim.grid, sim.marks, sim.tick, 0, &sim.events)
		sim.tick += 1
		dispatch_events(midi, sus, sim.events[:])
		host_send_snapshot(&st.conn, pid, sim.grid, sim.tick)
	}
}

// Stream the host's own grid to the room (reserved pid "host"), so it shows on
// the admin dashboard alongside the remote players.
host_send_own :: proc(st: ^Host_State, grid: orca.Grid, tick: uint) {
	if st.status == .Connected {
		host_send_snapshot(&st.conn, "host", grid, tick)
	}
}

host_shutdown :: proc(st: ^Host_State) {
	for _, sim in st.sims {
		host_free_sim(sim)
	}
	delete(st.sims)
	if st.status != .Disconnected {
		net_close(&st.conn)
	}
	st.status = .Disconnected
}

// run_net_host runs the host headlessly (no window): connect, then poll + tick
// on the VM clock forever, sounding via MIDI. `--net-host --headless`.
run_net_host :: proc(debug := false, want_room := "") {
	fmt.printfln("net-host: dialing 127.0.0.1:%d ...", NET_DEFAULT_PORT)
	st, ok := host_connect(want_room)
	if !ok {
		fmt.eprintln("net-host: could not connect to the server")
		os.exit(1)
	}
	defer host_shutdown(&st)
	fmt.printfln("net-host: hosting room %s", st.room)
	fmt.printfln("net-host: open http://localhost:4000/room/%s in a browser", st.room)
	fmt.println("net-host: simulating; Ctrl-C to quit ...")

	midi := midi_init(debug)
	sus: [dynamic]Sus_Note
	defer midi_shutdown(&midi)
	defer delete(sus)
	defer flush_notes(&midi, &sus) // runs first (LIFO): silence before shutdown
	if midi.ok {
		fmt.printfln("net-host: MIDI ready (hardware destination: %v)", midi.has_dest)
	} else {
		fmt.println("net-host: no MIDI output available")
	}

	frame := f64(frame_seconds(DEFAULT_BPM))
	last := time.tick_now()
	for {
		if !host_poll(&st) {
			fmt.println("net-host: server closed the connection")
			return
		}
		if time.duration_seconds(time.tick_since(last)) >= frame {
			last = time.tick_now()
			advance_notes(&midi, &sus)
			host_tick(&st, &midi, &sus)
		}
		free_all(context.temp_allocator)
		time.sleep(2 * time.Millisecond)
	}
}
