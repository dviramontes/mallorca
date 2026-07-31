#+build darwin
package main

import "core:testing"

@(test)
test_p2p_parse_roster_nicks_agent_gossip_shape :: proc(t: ^testing.T) {
	json := `{"peers":[{"nickname":"bob","last_seen_secs_ago":1,"quiet":false,"reach":"direct","transport":"unicast"}],"count":2}`
	nicks := p2p_parse_roster_nicks(json)
	testing.expect_value(t, len(nicks), 1)
	testing.expect_value(t, nicks[0], "bob")
}

@(test)
test_p2p_parse_roster_nicks_rejects_bare_array :: proc(t: ^testing.T) {
	// The old (wrong) expectation — a bare string array must not parse as a roster.
	nicks := p2p_parse_roster_nicks(`["bob"]`)
	testing.expect_value(t, len(nicks), 0)
}

@(test)
test_p2p_parse_roster_nicks_empty :: proc(t: ^testing.T) {
	testing.expect_value(t, len(p2p_parse_roster_nicks("")), 0)
	testing.expect_value(t, len(p2p_parse_roster_nicks(`{"peers":[],"count":1}`)), 0)
}
