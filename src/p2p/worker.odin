// The mesh worker thread: the only caller of the fofoca FFI once
// the pipe is open.
//
// Every FFI entry point wraps its work in `runtime.block_on` on the Rust side
// (crates/fofoca-ffi/src/pipe.rs), so whichever thread calls it
// parks until the tokio event loop replies. Owning a tokio runtime does not
// make the calls asynchronous *to the caller*. Left on the render thread that
// shows up as frame jitter, and midi.odin stamps CoreMIDI packets with "now"
// rather than scheduling ahead — so a stalled frame is an audible one.
//
// Only bytes, scalars, and JSON strings cross the thread boundary. Peer_Sim,
// orca.Grid, and State.sims stay on the render thread, which is why
// apply and all of the draw code need no locking at all.
//
// One worker, not several: Pipe::recv takes `&mut self` while send/peers_json/
// peer_count take `&self` (pipe.rs), so driving recv and send from two threads
// through the same handle would alias `&mut` with `&`.
#+build darwin
package p2p

import "core:c"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// How long the worker parks in recv before looping round to service the
// outbox. One 60Hz frame: long enough not to spin, short enough that a queued
// send is never delayed more than a frame, and it bounds how long
// worker_stop waits for the loop to notice it should exit.
RECV_TIMEOUT_MS :: 16

// The cadence roster_tick used to poll at when it called the FFI inline,
// preserved so join/leave reporting and the 15s alone-hint keep their timing.
ROSTER_PERIOD :: time.Second

// Queue ceilings. Hitting either means one side can't keep up with the other;
// drop rather than grow without bound, and count drops so it stays diagnosable.
// Snapshots are full-state and idempotent, so a dropped one is superseded by
// the next. A dropped frame mid-line corrupts one JSON line, which apply
// discards on unmarshal failure and which self-heals at the next newline.
INBOX_CAP :: 1024
OUTBOX_CAP :: 1024

// Frame receive buffer. A frame larger than the buffer is an error from the
// FFI, not a truncation.
RECV_BUF :: 65536

// One inbound frame, owned by the render thread once drained.
Inbound :: struct {
	nick:  string,
	eof:   bool,
	bytes: []u8,
}

// `to == ""` broadcasts; otherwise a directed send to that nickname.
Send_Req :: struct {
	to:      string,
	payload: []u8,
}

Merge_Req :: struct {
	json: string,
}

Request :: union {
	Send_Req,
	Merge_Req,
}

// The worker's view of the room, republished once per ROSTER_PERIOD.
// `generation` is what lets the render thread reconcile exactly once per fresh
// read, the way the old inline 1Hz poll did.
Roster_Snapshot :: struct {
	generation: u64,
	peer_count: int,
	peers_json: string,
	state_json: string,
}

Worker :: struct {
	pipe:        ^Pipe,
	thread:      ^thread.Thread,
	running:     bool, // atomic
	in_mu:       sync.Mutex,
	inbox:       [dynamic]Inbound,
	in_dropped:  u64,
	out_mu:      sync.Mutex,
	outbox:      [dynamic]Request,
	out_dropped: u64,
	ros_mu:      sync.Mutex,
	roster:      Roster_Snapshot,
	err_mu:      sync.Mutex,
	last_err:    string,
}

inbound_destroy :: proc(f: Inbound) {
	delete(f.nick)
	delete(f.bytes)
}

request_destroy :: proc(r: Request) {
	switch v in r {
	case Send_Req:
		delete(v.to)
		delete(v.payload)
	case Merge_Req:
		delete(v.json)
	}
}

// Spawn the worker. Called from open, so none of this exists in a
// single-player session.
worker_start :: proc(pipe: ^Pipe) -> ^Worker {
	w := new(Worker)
	w.pipe = pipe
	w.running = true
	w.inbox = make([dynamic]Inbound, 0, 32)
	w.outbox = make([dynamic]Request, 0, 32)

	// init_context is deliberately left unset. core:thread then hands the
	// thread the same context main() has — so context.allocator is one and the
	// same allocator on both sides and memory allocated here can be freed
	// there — while still giving it its own temp allocator, which core:thread
	// tears down when the thread dies.
	t := thread.create(worker_proc)
	t.data = w
	w.thread = t
	thread.start(t)
	return w
}

// Stop the worker and free everything it owns. The loop tests `running` once
// per iteration, so this blocks for at most one RECV_TIMEOUT_MS.
worker_stop :: proc(w: ^Worker) {
	if w == nil {
		return
	}
	sync.atomic_store(&w.running, false)
	if w.thread != nil {
		thread.join(w.thread)
		thread.destroy(w.thread)
		w.thread = nil
	}
	// The thread is gone, so the leftovers need no locking.
	for f in w.inbox {
		inbound_destroy(f)
	}
	delete(w.inbox)
	for r in w.outbox {
		request_destroy(r)
	}
	delete(w.outbox)
	delete(w.roster.peers_json)
	delete(w.roster.state_json)
	delete(w.last_err)
	free(w)
}

// Hand a request to the worker, transferring ownership of its payload. Returns
// false (having destroyed the request) when the queue is full.
worker_enqueue :: proc(w: ^Worker, req: Request) -> bool {
	sync.mutex_lock(&w.out_mu)
	defer sync.mutex_unlock(&w.out_mu)
	if len(w.outbox) >= OUTBOX_CAP {
		w.out_dropped += 1
		request_destroy(req)
		return false
	}
	append(&w.outbox, req)
	return true
}

// Swap the inbox into `dst`. The caller then owns every frame and must
// inbound_destroy them. Holding the lock for one slice exchange keeps the
// worker from ever stalling behind apply.
worker_drain_inbox :: proc(w: ^Worker, dst: ^[dynamic]Inbound) {
	clear(dst)
	sync.mutex_lock(&w.in_mu)
	w.inbox, dst^ = dst^, w.inbox
	sync.mutex_unlock(&w.in_mu)
}

// The published roster, if it changed since `last_gen`. The caller takes
// ownership of peers_json/state_json.
worker_take_roster :: proc(w: ^Worker, last_gen: u64) -> (snap: Roster_Snapshot, ok: bool) {
	sync.mutex_lock(&w.ros_mu)
	defer sync.mutex_unlock(&w.ros_mu)
	if w.roster.generation == last_gen {
		return {}, false
	}
	snap = w.roster
	// Ownership moves to the caller; clear the slot so the next publish
	// doesn't free strings the render thread is still reading.
	w.roster.peers_json = ""
	w.roster.state_json = ""
	return snap, true
}

// The pending worker-side error, transferring ownership. "" when there is none.
worker_take_error :: proc(w: ^Worker) -> string {
	sync.mutex_lock(&w.err_mu)
	defer sync.mutex_unlock(&w.err_mu)
	msg := w.last_err
	w.last_err = ""
	return msg
}

// Drop counters, for the status line / debugging.
worker_drops :: proc(w: ^Worker) -> (inbox: u64, outbox: u64) {
	sync.mutex_lock(&w.in_mu)
	inbox = w.in_dropped
	sync.mutex_unlock(&w.in_mu)
	sync.mutex_lock(&w.out_mu)
	outbox = w.out_dropped
	sync.mutex_unlock(&w.out_mu)
	return
}

// last_error lives in a thread_local slot on the Rust side, so a failure
// here is invisible to the render thread unless the worker captures it itself.
@(private = "file")
worker_fail :: proc(w: ^Worker) {
	msg := last_error_string(context.allocator)
	sync.mutex_lock(&w.err_mu)
	delete(w.last_err)
	w.last_err = msg
	sync.mutex_unlock(&w.err_mu)
}

@(private = "file")
worker_publish_roster :: proc(w: ^Worker, peer_count: int, peers, state: string) {
	sync.mutex_lock(&w.ros_mu)
	defer sync.mutex_unlock(&w.ros_mu)
	// A snapshot the render thread never collected: free it rather than leak.
	delete(w.roster.peers_json)
	delete(w.roster.state_json)
	w.roster.generation += 1
	w.roster.peer_count = peer_count
	w.roster.peers_json = peers
	w.roster.state_json = state
}

@(private = "file")
worker_proc :: proc(t: ^thread.Thread) {
	w := (^Worker)(t.data)
	buf := make([]u8, RECV_BUF)
	defer delete(buf)
	pending := make([dynamic]Request, 0, 32)
	defer delete(pending)

	// Poll the roster on the first iteration so the render thread has
	// something to reconcile without waiting out a full period.
	last_roster := time.tick_now()
	due := true

	for sync.atomic_load(&w.running) {
		worker_run_outbox(w, &pending)

		if due || time.tick_since(last_roster) >= ROSTER_PERIOD {
			due = false
			last_roster = time.tick_now()
			count := int(peer_count(w.pipe))
			// Heap, not temp: the render thread reads these long after this
			// iteration has reset our temp arena.
			peers := peers_json_string(w.pipe, context.allocator)
			state := state_json_string(w.pipe, context.allocator)
			worker_publish_roster(w, count, peers, state)
		}

		frame: Frame
		n := recv(w.pipe, raw_data(buf), c.size_t(len(buf)), RECV_TIMEOUT_MS, &frame)
		switch {
		case n > 0:
			worker_push_frame(w, &frame, buf)
		case n < 0:
			worker_fail(w)
		}

		free_all(context.temp_allocator)
	}
}

@(private = "file")
worker_run_outbox :: proc(w: ^Worker, pending: ^[dynamic]Request) {
	clear(pending)
	sync.mutex_lock(&w.out_mu)
	w.outbox, pending^ = pending^, w.outbox
	sync.mutex_unlock(&w.out_mu)

	for req in pending {
		failed := false
		switch v in req {
		case Send_Req:
			to_c: cstring = nil
			if v.to != "" {
				to_c = strings.clone_to_cstring(v.to, context.temp_allocator)
			}
			failed = send(w.pipe, to_c, raw_data(v.payload), c.size_t(len(v.payload))) < 0
		case Merge_Req:
			cstr := strings.clone_to_cstring(v.json, context.temp_allocator)
			failed = state_merge(w.pipe, cstr) < 0
		}
		if failed {
			worker_fail(w)
		}
		request_destroy(req)
	}
	clear(pending)
}

@(private = "file")
worker_push_frame :: proc(w: ^Worker, frame: ^Frame, buf: []u8) {
	flen := min(int(frame.len), len(buf))
	nick := strings.clone(frame_nick(frame))
	bytes := make([]u8, flen)
	copy(bytes, buf[:flen])

	sync.mutex_lock(&w.in_mu)
	defer sync.mutex_unlock(&w.in_mu)
	if len(w.inbox) >= INBOX_CAP {
		w.in_dropped += 1
		delete(nick)
		delete(bytes)
		return
	}
	append(&w.inbox, Inbound{nick = nick, eof = frame.eof != 0, bytes = bytes})
}

// The nickname a frame arrived from/for: NUL-terminated within the fixed
// 64-byte field. Borrows from `frame`; clone before it outlives the call.
frame_nick :: proc(frame: ^Frame) -> string {
	n := 0
	for n < len(frame.nick) && frame.nick[n] != 0 {
		n += 1
	}
	return string(frame.nick[:n])
}
