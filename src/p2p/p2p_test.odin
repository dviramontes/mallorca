#+build darwin
package p2p

import orca "../core"
import "core:testing"

// Tear down a pipe-less State built by hand in a test. Frees the cloned
// map keys too, which shutdown does not.
// Mirrors free_sim, which is file-private to p2p.odin.
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
	// Local empty: first non-empty remote in tint order.
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

@(test)
test_p2p_tint_from_name_stable_and_in_palette :: proc(t: ^testing.T) {
	a := tint_from_name("alice")
	testing.expect_value(t, a, tint_from_name("alice"))
	testing.expect(t, a >= 0 && a < TINT_COUNT)
	// Different names should usually differ; not a hard guarantee across the
	// whole palette, but these two are known to land on different slots.
	testing.expect(t, tint_from_name("alice") != tint_from_name("bob"))
}
