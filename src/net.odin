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

// Send hello and parse the welcome; returns the room code assigned by the
// server. Shared by the spike and host modes.
@(private = "file")
net_hello :: proc(c: ^Net_Conn) -> (room: string, ok: bool) {
	net_send_line(c, `{"t":"hello","v":1,"role":"host","name":"mallorca-host"}`)
	wline, wok := net_read_line(c)
	if !wok {
		fmt.eprintln("net: no welcome (server closed?)")
		return "", false
	}
	Welcome :: struct {
		t:       string,
		room:    string,
		bpm:     int,
		playing: bool,
	}
	w: Welcome
	if err := json.unmarshal(transmute([]u8)wline, &w); err != nil {
		fmt.eprintfln("net: bad welcome %q: %v", wline, err)
		return "", false
	}
	fmt.printfln("net: <- welcome  room=%s bpm=%d playing=%v", w.room, w.bpm, w.playing)
	return w.room, true
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

	if _, hok := net_hello(&c); !hok {
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

// run_net_host connects as the room host and stays connected, printing player
// events (player_join / player_leave) as browsers come and go. A stand-in for
// the real host loop until the app is wired to the network. `--net-host`.
run_net_host :: proc() {
	fmt.printfln("net-host: dialing 127.0.0.1:%d ...", NET_DEFAULT_PORT)
	c, ok := net_dial()
	if !ok {
		os.exit(1)
	}
	defer net_close(&c)

	room, hok := net_hello(&c)
	if !hok {
		os.exit(1)
	}
	fmt.printfln("net-host: hosting room %s", room)
	fmt.printfln("net-host: open http://localhost:4000/room/%s in a browser", room)
	fmt.println("net-host: waiting for player events (Ctrl-C to quit) ...")

	for {
		line, lok := net_read_line(&c)
		if !lok {
			fmt.println("net-host: server closed the connection")
			break
		}
		fmt.printfln("net-host: <- %s", line)
	}
}
