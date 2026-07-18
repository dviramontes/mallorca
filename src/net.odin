// Network client for mallorca's host <-> server link (PLAN.md M6).
// Line-delimited JSON over TCP; see docs/m6-network-protocol.md.
//
// M6 spike scope: dial, hello/welcome handshake, ping/pong round-trip. Later
// milestones build player lifecycle, edits, snapshots, and transport on top of
// the Net_Conn read/write primitives here.
package main

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:time"
import orca "core"

NET_DEFAULT_PORT :: 4001

// A framed connection: the socket plus a buffer of bytes received but not yet
// split into a line (recv can return partial lines or several at once).
Net_Conn :: struct {
	sock: net.TCP_Socket,
	rbuf: [dynamic]u8,
}

net_dial :: proc(port: int = NET_DEFAULT_PORT) -> (conn: Net_Conn, ok: bool) {
	endpoint := net.Endpoint{address = net.IP4_Loopback, port = port}
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
net_hello :: proc(c: ^Net_Conn, room := "") -> (assigned: string, players: []Welcome_Player, ok: bool) {
	hello :=
		room != "" \
		? fmt.tprintf(`{"t":"hello","v":1,"role":"host","name":"mallorca-host","room":"%s"}`, room) \
		: `{"t":"hello","v":1,"role":"host","name":"mallorca-host"}`
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

// A per-player simulation the host owns: its grid + marks + scratch events.
@(private = "file")
Host_Sim :: struct {
	grid:   orca.Grid,
	marks:  []orca.Mark,
	events: [dynamic]orca.Event,
	tick:   uint,
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
host_send_snapshot :: proc(c: ^Net_Conn, pid: string, sim: ^Host_Sim) {
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
		w    = sim.grid.width,
		h    = sim.grid.height,
		grid = string(sim.grid.cells),
		tick = sim.tick,
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
	free(sim)
}

// run_net_host connects as the room host and simulates a grid per player: it
// applies remote edits, ticks every grid on the host clock, and streams the
// evaluated grid back for each player. Headless stand-in for the app's host
// loop (no window, no MIDI yet). `--net-host`.
run_net_host :: proc(debug := false, want_room := "") {
	fmt.printfln("net-host: dialing 127.0.0.1:%d ...", NET_DEFAULT_PORT)
	c, ok := net_dial()
	if !ok {
		os.exit(1)
	}
	defer net_close(&c)

	assigned, players, hok := net_hello(&c, want_room)
	if !hok {
		os.exit(1)
	}
	room := assigned
	fmt.printfln("net-host: hosting room %s", room)
	fmt.printfln("net-host: open http://localhost:4000/room/%s in a browser", room)
	fmt.println("net-host: simulating; Ctrl-C to quit ...")

	sims := make(map[string]^Host_Sim)
	defer {
		for _, sim in sims {
			host_free_sim(sim)
		}
		delete(sims)
	}

	// One flat struct covers player_join / player_leave / edit (json.unmarshal
	// ignores absent fields).
	Host_Msg :: struct {
		t:    string,
		pid:  string,
		name: string,
		x:    int,
		y:    int,
		g:    string,
	}

	// MIDI output is shared across all players (one device, one channel space).
	// Note scheduling reuses the app's frame-counted scheduler (main.odin).
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

	// Seed a grid for players who were already in the room before we attached.
	for p in players {
		if p.pid != "" && p.pid not_in sims {
			sim := new(Host_Sim)
			sim.grid = orca.make_grid(DEFAULT_W, DEFAULT_H)
			sim.marks = orca.make_marks(sim.grid)
			sims[strings.clone(p.pid)] = sim
			fmt.printfln("net-host: + player %s (%s) [existing]", p.name, p.pid)
			host_send_snapshot(&c, p.pid, sim)
		}
	}

	net.set_blocking(c.sock, false)
	frame := f64(frame_seconds(DEFAULT_BPM))
	last := time.tick_now()

	for {
		// Drain any pending messages from the server.
		drain: for {
			line, st := net_poll_line(&c)
			switch st {
			case .Closed:
				fmt.println("net-host: server closed the connection")
				return
			case .Empty:
				break drain
			case .Line:
				m: Host_Msg
				if json.unmarshal(transmute([]u8)line, &m, allocator = context.temp_allocator) !=
				   nil {
					continue
				}
				switch m.t {
				case "player_join":
					if m.pid not_in sims {
						sim := new(Host_Sim)
						sim.grid = orca.make_grid(DEFAULT_W, DEFAULT_H)
						sim.marks = orca.make_marks(sim.grid)
						sims[strings.clone(m.pid)] = sim
						fmt.printfln("net-host: + player %s (%s)", m.name, m.pid)
						host_send_snapshot(&c, m.pid, sim)
					}
				case "player_leave":
					if sim, found := sims[m.pid]; found {
						host_free_sim(sim)
						delete_key(&sims, m.pid)
						fmt.printfln("net-host: - player %s", m.pid)
					}
				case "edit":
					if sim, found := sims[m.pid]; found && len(m.g) > 0 {
						orca.grid_set(sim.grid, m.x, m.y, m.g[0])
					}
				}
			}
		}

		// Tick every grid on the host clock, then stream each evaluated grid.
		if time.duration_seconds(time.tick_since(last)) >= frame {
			last = time.tick_now()
			advance_notes(&midi, &sus) // expire notes from earlier ticks first
			for pid, sim in sims {
				orca.run_tick(sim.grid, sim.marks, sim.tick, 0, &sim.events)
				sim.tick += 1
				dispatch_events(&midi, &sus, sim.events[:]) // sound this tick's events
				host_send_snapshot(&c, pid, sim)
			}
		}

		free_all(context.temp_allocator)
		time.sleep(2 * time.Millisecond)
	}
}
