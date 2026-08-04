// UDP output for Orca's ';' operator. Pilot listens for command datagrams on
// localhost:49161, the port used by the original Orca/Pilot pairing.
package main

import "core:fmt"
import "core:net"

PILOT_UDP_PORT :: 49161

Udp_Output :: struct {
	socket: net.UDP_Socket,
	target: net.Endpoint,
	ok:     bool,
	debug:  bool,
}

udp_init :: proc(debug := false) -> (out: Udp_Output) {
	out.debug = debug
	out.target = net.Endpoint{address = net.IP4_Loopback, port = PILOT_UDP_PORT}
	socket, err := net.make_unbound_udp_socket(.IP4)
	if err != nil {
		if debug {
			fmt.eprintfln("udp: socket creation failed: %v", err)
		}
		return
	}
	out.socket = socket
	out.ok = true
	return
}

udp_shutdown :: proc(out: ^Udp_Output) {
	if out.ok {
		net.close(out.socket)
	}
	out^ = {}
}

udp_send :: proc(out: ^Udp_Output, data: []u8) {
	if !out.ok || len(data) == 0 {
		return
	}
	n, err := net.send_udp(out.socket, data, out.target)
	if err != nil {
		fmt.eprintfln("udp: send to 127.0.0.1:%d failed: %v", PILOT_UDP_PORT, err)
		return
	}
	if out.debug {
		fmt.eprintfln("udp tx %d bytes to 127.0.0.1:%d: %s", n, PILOT_UDP_PORT, string(data))
	}
}
