#+build darwin
package p2p

import orca "../core"
import "core:strings"
import "core:testing"

// Tear down a pipe-less State built by hand in a test. Mirrors the sim/key
// freeing shutdown does (free_sim + the cloned map keys), inlined here because
// free_sim is file-private to p2p.odin and shutdown needs a live worker/pipe.
@(private = "file")
test_teardown :: proc(st: ^State) {
	for nick, sim in st.sims {
		orca.destroy_grid(&sim.grid)
		delete(sim.marks)
		delete(sim.seqs)
		delete(sim.name)
		free(sim)
		delete(nick)
	}
	delete(st.sims)
	for nick, buf in st.rx {
		delete(buf^)
		free(buf)
		delete(nick)
	}
	delete(st.rx)
}

@(private = "file")
SNAP_LINE: string : `{"t":"snapshot","w":2,"h":1,"grid":"ab","tick":3,"ink":[]}` + "\n"

@(test)
test_p2p_feed_reassembles_split_frames :: proc(t: ^testing.T) {
	st: State
	st.sims = make(map[string]^Peer_Sim)
	st.rx = make(map[string]^[dynamic]u8)
	defer test_teardown(&st)

	// A snapshot arriving as two frames must not apply until the newline does.
	// This is the case the worker queue makes more likely, not less: frames are
	// now delivered in batches rather than drained one at a time.
	feed(&st, "bob", transmute([]u8)SNAP_LINE[:20])
	testing.expect_value(t, len(st.sims), 0)

	feed(&st, "bob", transmute([]u8)SNAP_LINE[20:])
	testing.expect_value(t, len(st.sims), 1)

	sim := st.sims["bob"]
	testing.expect_value(t, sim.tick, uint(3))
	testing.expect_value(t, string(sim.grid.cells), "ab")
}

@(test)
test_p2p_feed_applies_two_lines_in_one_frame :: proc(t: ^testing.T) {
	st: State
	st.sims = make(map[string]^Peer_Sim)
	st.rx = make(map[string]^[dynamic]u8)
	defer test_teardown(&st)

	both := SNAP_LINE + `{"t":"snapshot","w":2,"h":1,"grid":"cd","tick":9,"ink":[]}` + "\n"
	feed(&st, "bob", transmute([]u8)both)

	testing.expect_value(t, len(st.sims), 1)
	sim := st.sims["bob"]
	// Last line wins; both were consumed, leaving no partial residue.
	testing.expect_value(t, sim.tick, uint(9))
	testing.expect_value(t, string(sim.grid.cells), "cd")
	testing.expect_value(t, len(st.rx["bob"]^), 0)
}

@(test)
test_p2p_feed_drops_malformed_line_and_recovers :: proc(t: ^testing.T) {
	st: State
	st.sims = make(map[string]^Peer_Sim)
	st.rx = make(map[string]^[dynamic]u8)
	defer test_teardown(&st)

	// A dropped frame corrupts the line it was part of. That line must be
	// discarded without taking the stream down — the next newline resyncs.
	feed(&st, "bob", transmute([]u8)string("{\"t\":\"snap\x00garbage\n"))
	testing.expect_value(t, len(st.sims), 0)

	feed(&st, "bob", transmute([]u8)SNAP_LINE)
	testing.expect_value(t, len(st.sims), 1)
	testing.expect_value(t, st.sims["bob"].tick, uint(3))
}


@(test)
test_p2p_parse_roster_nicks_agent_gossip_shape :: proc(t: ^testing.T) {
	json := `{"peers":[{"nickname":"bob","last_seen_secs_ago":1,"quiet":false,"reach":"direct","transport":"unicast"}],"count":2}`
	nicks, ok := parse_roster_nicks(json)
	testing.expect(t, ok)
	testing.expect_value(t, len(nicks), 1)
	testing.expect_value(t, nicks[0], "bob")
}

@(test)
test_p2p_parse_roster_nicks_rejects_bare_array :: proc(t: ^testing.T) {
	// The old (wrong) expectation — a bare string array must not parse as a roster.
	nicks, ok := parse_roster_nicks(`["bob"]`)
	testing.expect(t, !ok)
	testing.expect_value(t, len(nicks), 0)
}

@(test)
test_p2p_parse_roster_nicks_empty :: proc(t: ^testing.T) {
	_, ok_empty := parse_roster_nicks("")
	testing.expect(t, !ok_empty)
	nicks, ok := parse_roster_nicks(`{"peers":[],"count":1}`)
	testing.expect(t, ok)
	testing.expect_value(t, len(nicks), 0)
}

@(test)
test_p2p_jam_pick_newer_seq_wins :: proc(t: ^testing.T) {
	remotes := []Jam_Remote_Cell{{glyph = 'B', seq = 2, tint = 0}}
	glyph, tint := jam_pick('A', 1, remotes)
	testing.expect_value(t, glyph, u8('B'))
	testing.expect_value(t, tint, 0)
}

@(test)
test_p2p_jam_pick_clear_beats_older_remote :: proc(t: ^testing.T) {
	// Local clear with a higher seq must hide an older remote glyph.
	remotes := []Jam_Remote_Cell{{glyph = 'D', seq = 3, tint = 1}}
	glyph, tint := jam_pick(orca.EMPTY_GLYPH, 4, remotes)
	testing.expect_value(t, glyph, orca.EMPTY_GLYPH)
	testing.expect_value(t, tint, JAM_LOCAL)
}

@(test)
test_p2p_jam_pick_seq0_falls_back_to_overlay :: proc(t: ^testing.T) {
	// No user claims: local non-empty wins.
	g, tint := jam_pick('A', 0, []Jam_Remote_Cell{{glyph = 'B', seq = 0, tint = 0}})
	testing.expect_value(t, g, u8('A'))
	testing.expect_value(t, tint, JAM_LOCAL)
	// Local empty: first non-empty remote in the caller's (join) order.
	g, tint = jam_pick(
		orca.EMPTY_GLYPH,
		0,
		[]Jam_Remote_Cell {
			{glyph = orca.EMPTY_GLYPH, seq = 0, tint = 0},
			{glyph = 'C', seq = 0, tint = 1},
		},
	)
	testing.expect_value(t, g, u8('C'))
	testing.expect_value(t, tint, 1)
}

@(test)
test_p2p_ink_from_seqs_sparse :: proc(t: ^testing.T) {
	seqs := []u64{0, 5, 0, 2}
	ink := ink_from_seqs(seqs, 2, 2)
	testing.expect_value(t, len(ink), 2)
	testing.expect_value(t, ink[0].x, 1)
	testing.expect_value(t, ink[0].y, 0)
	testing.expect_value(t, ink[0].s, u64(5))
	testing.expect_value(t, ink[1].x, 1)
	testing.expect_value(t, ink[1].y, 1)
	testing.expect_value(t, ink[1].s, u64(2))
}

// --- roster_tick harness -------------------------------------------------
//
// roster_tick needs a non-nil worker but never touches its pipe: it only reads
// the published roster and the error slot (both plain fields behind mutexes,
// which zero-init unlocked), and enqueues backfills onto the outbox. So a
// hand-built Worker with no thread is a legitimate fixture, same as
// worker_test.odin. These drive the fix-1 (greet exactly once, whoever created
// the sim) and fix-2 (a departure frees the sim, both cloned keys, and the rx
// buffer — no leak) paths, verified under the test runner's memory tracker.

@(private = "file")
publish_roster :: proc(w: ^Worker, gen: u64, peer_count: int, peers_json: string) {
	// Mirrors what worker_publish_roster does on the worker thread: replace the
	// slot's owned string, bump the generation so the next take reads as fresh.
	delete(w.roster.peers_json)
	w.roster.generation = gen
	w.roster.peer_count = peer_count
	w.roster.peers_json = strings.clone(peers_json)
	w.roster.state_json = ""
}

@(private = "file")
teardown_worker :: proc(w: ^Worker) {
	for r in w.outbox {
		request_destroy(r)
	}
	delete(w.outbox)
	delete(w.roster.peers_json)
	delete(w.roster.state_json)
	delete(w.last_err)
}

@(private = "file")
has_status :: proc(lines: []string, want: string) -> bool {
	for l in lines {
		if l == want {
			return true
		}
	}
	return false
}

@(test)
test_p2p_roster_tick_greets_apply_created_sim_once :: proc(t: ^testing.T) {
	st: State
	st.sims = make(map[string]^Peer_Sim)
	st.rx = make(map[string]^[dynamic]u8)
	st.nick = "me"
	defer test_teardown(&st)

	w: Worker
	st.worker = &w
	defer teardown_worker(&w)

	grid := orca.make_grid(2, 1)
	defer orca.destroy_grid(&grid)
	edit_seqs := make([]u64, 2)
	defer delete(edit_seqs)

	// A snapshot from "bob" reaches us before the first roster read, so apply()
	// creates the sim (announced still false). This is the race fix 1 targets.
	feed(&st, "bob", transmute([]u8)SNAP_LINE)
	testing.expect_value(t, len(st.sims), 1)
	testing.expect(t, !st.sims["bob"].announced)

	// First roster listing bob: greet fires even though the sim already exists.
	publish_roster(&w, 1, 1, `{"peers":[{"nickname":"bob"}]}`)
	res1 := roster_tick(&st, grid, 0, edit_seqs, 120, false, 10, 300)
	testing.expect(t, has_status(res1.statuses, "bob joined"))
	testing.expect(t, st.sims["bob"].announced)
	// Backfill of our own grid was queued directly to bob.
	testing.expect_value(t, len(w.outbox), 1)
	send, is_send := w.outbox[0].(Send_Req)
	testing.expect(t, is_send)
	testing.expect_value(t, send.to, "bob")

	// A second fresh roster with bob still present must not re-greet or re-queue.
	publish_roster(&w, 2, 1, `{"peers":[{"nickname":"bob"}]}`)
	res2 := roster_tick(&st, grid, 0, edit_seqs, 120, false, 10, 300)
	testing.expect(t, !has_status(res2.statuses, "bob joined"))
	testing.expect_value(t, len(res2.statuses), 0)
	testing.expect_value(t, len(w.outbox), 1)
}

@(test)
test_p2p_roster_tick_departure_frees_sim_and_buffers :: proc(t: ^testing.T) {
	st: State
	st.sims = make(map[string]^Peer_Sim)
	st.rx = make(map[string]^[dynamic]u8)
	st.nick = "me"
	defer test_teardown(&st)

	w: Worker
	st.worker = &w
	defer teardown_worker(&w)

	grid := orca.make_grid(2, 1)
	defer orca.destroy_grid(&grid)
	edit_seqs := make([]u64, 2)
	defer delete(edit_seqs)

	// bob has a sim and a non-empty rx line-buffer (a partial line still
	// pending reassembly) — exactly the state a departure must fully reclaim.
	feed(&st, "bob", transmute([]u8)SNAP_LINE)
	feed(&st, "bob", transmute([]u8)string("partial-no-newline"))
	testing.expect_value(t, len(st.sims), 1)
	testing.expect_value(t, len(st.rx), 1)

	publish_roster(&w, 1, 1, `{"peers":[{"nickname":"bob"}]}`)
	roster_tick(&st, grid, 0, edit_seqs, 120, false, 10, 300)

	// bob drops out of the roster: the sim, both cloned map keys, and the rx
	// buffer must all be freed. A leak here trips the memory tracker; a
	// use-after-free on the aliased key would crash the run.
	publish_roster(&w, 2, 0, `{"peers":[]}`)
	res := roster_tick(&st, grid, 0, edit_seqs, 120, false, 10, 300)
	testing.expect(t, has_status(res.statuses, "bob left"))
	testing.expect_value(t, len(st.sims), 0)
	testing.expect_value(t, len(st.rx), 0)
	testing.expect_value(t, st.status, Status.Alone)
}

@(test)
test_p2p_roster_tick_adopts_transport_with_peer :: proc(t: ^testing.T) {
	st: State
	st.sims = make(map[string]^Peer_Sim)
	st.rx = make(map[string]^[dynamic]u8)
	st.nick = "me"
	defer test_teardown(&st)

	w: Worker
	st.worker = &w
	defer teardown_worker(&w)

	grid := orca.make_grid(2, 1)
	defer orca.destroy_grid(&grid)
	edit_seqs := make([]u64, 2)
	defer delete(edit_seqs)

	// A peer is present AND the shared doc carries transport state — the exact
	// shape active during a live jam. Exercises the adopt path (status line +
	// state_json free) under the test memory tracker.
	feed(&st, "bob", transmute([]u8)SNAP_LINE)
	w.roster.generation = 1
	w.roster.peer_count = 1
	w.roster.peers_json = strings.clone(`{"peers":[{"nickname":"bob"}]}`)
	w.roster.state_json = strings.clone(`{"bpm":140,"playing":true}`)

	// local bpm 120, playing false → both differ from the doc, so both adopt.
	res := roster_tick(&st, grid, 0, edit_seqs, 120, false, 10, 300)
	bpm, bpm_ok := res.bpm.?
	testing.expect(t, bpm_ok)
	testing.expect_value(t, bpm, 140)
	playing, play_ok := res.playing.?
	testing.expect(t, play_ok)
	testing.expect_value(t, playing, true)
	testing.expect(t, has_status(res.statuses, "bpm synced to 140"))
	testing.expect(t, has_status(res.statuses, "playing (synced)"))
}

@(test)
test_p2p_apply_dim_change_realloc_clean :: proc(t: ^testing.T) {
	st: State
	st.sims = make(map[string]^Peer_Sim)
	st.rx = make(map[string]^[dynamic]u8)
	st.nick = "me"
	defer test_teardown(&st)

	w: Worker
	st.worker = &w
	defer teardown_worker(&w)

	grid := orca.make_grid(3, 2) // "our" grid, larger than the peer's
	defer orca.destroy_grid(&grid)
	edit_seqs := make([]u64, 6)
	defer delete(edit_seqs)

	// roster creates bob's sim at OUR dims (3x2); then bob's own snapshot arrives
	// at a DIFFERENT size (2x1), forcing apply's realloc/free path — grid, marks,
	// and seqs all reallocated. A double-free there trips the tracker.
	publish_roster(&w, 1, 1, `{"peers":[{"nickname":"bob"}]}`)
	roster_tick(&st, grid, 0, edit_seqs, 120, false, 10, 300)
	testing.expect_value(t, st.sims["bob"].grid.width, 3)

	feed(&st, "bob", transmute([]u8)SNAP_LINE) // 2x1 "ab"
	testing.expect_value(t, st.sims["bob"].grid.width, 2)
	testing.expect_value(t, st.sims["bob"].grid.height, 1)
	testing.expect_value(t, string(st.sims["bob"].grid.cells), "ab")

	// and back up a size, exercising the grow direction too.
	feed(&st, "bob", transmute([]u8)string(`{"t":"snapshot","w":3,"h":2,"grid":"abcdef","tick":5,"ink":[]}`+"\n"))
	testing.expect_value(t, st.sims["bob"].grid.width, 3)
	testing.expect_value(t, string(st.sims["bob"].grid.cells), "abcdef")
}

@(test)
test_p2p_tint_from_name_stable_and_in_palette :: proc(t: ^testing.T) {
	a := tint_from_name("alice")
	testing.expect_value(t, a, tint_from_name("alice"))
	testing.expect(t, a >= 0 && a < TINT_COUNT)
	// Different names should usually differ; not a hard guarantee across the
	// whole palette, but these two are known to land on different slots.
	testing.expect(t, tint_from_name("alice") != tint_from_name("bob"))
}
