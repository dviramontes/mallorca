// Queue and slot semantics for the mesh worker. These exercise the thread
// boundary's bookkeeping without a live mesh: every proc under test touches
// only mutexes and the queues, never `pipe`, so a zero-valued Worker with
// no thread attached is a legitimate fixture (sync.Mutex zero-inits unlocked).
#+build darwin
package p2p

import "core:strings"
import "core:testing"

@(test)
test_mesh_worker_drain_inbox_swaps :: proc(t: ^testing.T) {
	w: Worker
	w.inbox = make([dynamic]Inbound, 0, 4)
	defer delete(w.inbox)
	batch := make([dynamic]Inbound, 0, 4)
	defer delete(batch)

	append(&w.inbox, Inbound{nick = strings.clone("bob"), bytes = []u8{1, 2}})

	worker_drain_inbox(&w, &batch)
	testing.expect_value(t, len(batch), 1)
	testing.expect_value(t, batch[0].nick, "bob")
	// The worker's queue is now empty, so the next frame starts from scratch.
	testing.expect_value(t, len(w.inbox), 0)
	delete(batch[0].nick)

	// Draining again yields nothing rather than repeating the batch.
	clear(&batch)
	worker_drain_inbox(&w, &batch)
	testing.expect_value(t, len(batch), 0)
}

@(test)
test_mesh_worker_enqueue_rejects_when_full :: proc(t: ^testing.T) {
	w: Worker
	w.outbox = make([dynamic]Request, 0, OUTBOX_CAP)
	defer {
		for r in w.outbox {
			request_destroy(r)
		}
		delete(w.outbox)
	}

	for _ in 0 ..< OUTBOX_CAP {
		ok := worker_enqueue(&w, Merge_Req{json = strings.clone("{}")})
		testing.expect(t, ok)
	}
	testing.expect_value(t, len(w.outbox), OUTBOX_CAP)

	// The overflowing request is destroyed by the enqueue, not leaked and not
	// appended — otherwise a stalled mesh would grow this queue forever.
	testing.expect(t, !worker_enqueue(&w, Merge_Req{json = strings.clone("{}")}))
	testing.expect_value(t, len(w.outbox), OUTBOX_CAP)
	testing.expect_value(t, w.out_dropped, u64(1))
}

@(test)
test_mesh_worker_roster_generation_gates_reconcile :: proc(t: ^testing.T) {
	w: Worker

	// Nothing published yet: generation 0 matches the caller's 0.
	_, fresh := worker_take_roster(&w, 0)
	testing.expect(t, !fresh)

	w.roster.generation = 1
	w.roster.peer_count = 2
	w.roster.peers_json = strings.clone(`{"peers":[]}`)
	w.roster.state_json = strings.clone(`{"bpm":120}`)

	snap, ok := worker_take_roster(&w, 0)
	testing.expect(t, ok)
	testing.expect_value(t, snap.peer_count, 2)
	testing.expect_value(t, snap.state_json, `{"bpm":120}`)
	// Ownership moved out, so a later publish can't free what the render
	// thread is still reading.
	testing.expect_value(t, w.roster.peers_json, "")
	testing.expect_value(t, w.roster.state_json, "")
	delete(snap.peers_json)
	delete(snap.state_json)

	// Same generation: stale, so the caller reconciles exactly once per read.
	_, again := worker_take_roster(&w, snap.generation)
	testing.expect(t, !again)
}

@(test)
test_mesh_worker_error_slot_transfers_ownership :: proc(t: ^testing.T) {
	w: Worker
	testing.expect_value(t, worker_take_error(&w), "")

	w.last_err = strings.clone("event loop stopped")
	msg := worker_take_error(&w)
	testing.expect_value(t, msg, "event loop stopped")
	delete(msg)

	// Taken once only — the status line shouldn't repeat a stale error.
	testing.expect_value(t, w.last_err, "")
	testing.expect_value(t, worker_take_error(&w), "")
}
