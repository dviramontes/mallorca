# P2P room protocol

Wire protocol for mallorca's serverless p2p rooms, built on
[fofoca](https://github.com/fofoca-network/fofoca) (an iroh-based gossip
mesh, cloned into `fofoca/` by `just setup`). Replaces the Phoenix host↔server
link described in [m6-network-protocol.md](m6-network-protocol.md) (superseded,
kept for historical context). See `src/p2p/` for the state machine that
implements this document, and `src/p2p/fofoca_ffi.odin` for the raw C binding.
[ffi-cost.md](ffi-cost.md) measures what the mesh costs in binary size, CPU and
RAM — including a ~5 s render-thread stall on join that this document's cadence
rules do not account for.

## 1. Model

Every peer is authoritative for its own grid only and broadcasts its full,
evaluated grid as a `snapshot`. Remote peers are display replicas — they are
never ticked locally, only redrawn from the latest snapshot received. This
avoids edit-replay convergence problems (`run_tick` mutates operator state and
mixes the tick into randomness, so two independently-ticking replicas of the
same edits diverge) at the cost of ~1.5 KB/snapshot at up to 8 msg/s per peer,
which is trivial for a handful of grids.

There is no server, no room code issued by anything but the mesh itself, and
no host: every peer in a room is a symmetric participant.

## 2. Transport

Messages ride mesh frames (`mesh_send`/`mesh_recv` in `mesh.odin`), each frame
a chunk of a byte stream to or from one peer, identified by mesh nickname —
not a message boundary. Framing is newline-delimited JSON: each logical
message is one JSON object followed by `\n`; a receiver accumulates bytes
per-sender-nick and splits complete lines off the front of that buffer as they
arrive (`p2p_poll` in `p2p.odin`). A frame carrying your own nickname (the
mesh's self-echo on a broadcast) is dropped unprocessed.

## 3. Message catalog

There is exactly one message type.

| `t` | Fields | Meaning |
| --- | --- | --- |
| `snapshot` | `w`, `h`, `grid`, `tick`, `ink?` | The sender's evaluated grid. `grid` is a single row-major string of length `w*h`, `.` for empty — the same encoding M6 used (§2 there), reused verbatim. Optional `ink` is a sparse array of `{x,y,s}` for every cell the sender has user-edited (`s` is that peer's monotonic edit generation, `s > 0`). Glyphs stay in `grid`; `ink` only carries authorship time for jam last-write-wins. |

Any other `t` is dropped without error (forward-compatible with future message
types, e.g. cursor sharing). Unknown fields (including a missing `ink`) are
ignored. There is no envelope beyond `t` — no sender id field, because the mesh
frame itself already carries the sender's nickname.

### Jam canvas (last-write-wins)

Each peer still ticks only its own grid. The host view composites local + remote
grids per cell:

1. Among local and every remote, the entry with the highest ink `s` wins —
   including when that glyph is `.` (a clear beats an older remote glyph).
2. Winner color: local → white (author's own ink); remote → that peer's
   palette color, chosen by hashing their nickname into `REMOTE_TINTS`.
3. If every `s` is 0 (no user claim on that cell): legacy behavior — local
   glyph if non-empty, else remotes in join order on empty local cells.

Remote glyphs are never copied into the local VM; LWW is display-only so MIDI
authority stays per-peer.

Cadence: while playing, at most one snapshot per tick (~8/s at 120 BPM ÷ 4
frames/beat), broadcast to every peer. While paused, one snapshot per applied
edit. Broadcasts are skipped entirely when the room has no other peers
(`mesh_peer_count() == 0`).

## 4. Presence: roster polling, not join/leave messages

There are no `player_join`/`player_leave` messages. Once per second,
`p2p_roster_tick` calls `mesh_peers_json()` (the agent-gossip roster document
`{"peers":[{"nickname":…},…],"count":N}`) and diffs the nicknames against
the peers already tracked:

- **New nickname** → create a sim for it (grid sized to match ours; draw
  color = hash(nickname) into the peer palette; a separate join-order id is
  used only for `` ` `` view cycling) and send it one **directed** snapshot of
  our own grid — a backfill, because mesh frames aren't retained and a peer
  that joined mid-session has seen nothing yet. A transient status line
  announces the join.
- **Nickname no longer present** → free its sim and drop its partial-line
  receive buffer. A transient status line announces the leave.
- **Roster JSON unreadable while `mesh_peer_count > 0`** → skip join/leave
  reconciliation that tick (keep existing sims). Avoids a grow-during-read
  empty parse wiping every remote.
- **Own nickname present in the roster** → warned once (nickname collision
  with another peer in the same room); this is cosmetic only, mesh routing is
  by its own peer identity, not the display nickname.

A peer joining in `--join-room` mode with zero peers for 15 consecutive
seconds gets a one-shot hint that the room id may be wrong.

## 5. Presence status (connection indicator)

Local UI state only, never sent on the wire, driven by `mesh_peer_count()`:

| Status | Meaning |
| --- | --- |
| `Offline` | No room open, or the mesh reported an error. |
| `Alone` | Room open, 0 peers. |
| `Connected` | Room open, ≥1 peer. |

## 6. Shared transport state (bpm/playing)

`mesh_state_merge`/`mesh_state_json` expose a per-room RFC 7386 JSON document,
CRDT-merged across peers (see fofoca's `mesh-state` extension).
`p2p_share_transport(st, bpm, playing)` marshals `{bpm, playing}` and merges it
into that doc; `toggle_play` and `adjust_bpm` (`main.odin`) call it whenever
the local player changes tempo or play/pause, so every transport change gets
pushed, not just the value at some poll interval.

Adoption happens once per second, folded into `p2p_roster_tick`: it reads the
merged doc back with `mesh_state_json` and applies a field only when it
differs from **both** the app's current local value and `P2p_State`'s
`last_synced_bpm`/`last_synced_playing`. That second check is a feedback
guard — without it, a peer's own merge would round-trip back through the CRDT
doc on the next poll and get misread as a remote change, self-triggering a
`"bpm synced to N"` / `"playing (synced)"` status message for a value that
peer already set itself. `last_synced_*` is updated on both the push side
(`p2p_share_transport`) and the adopt side, so either one "claims" a value and
the other's poll treats it as already known.

There is no leader election: whichever peer's merge lands last in the CRDT
doc wins, same as any other key in a last-write-wins RFC 7386 merge. Adopting
a `playing` transition to `false` also flushes locally sustained MIDI notes
(`flush_notes`), matching what a local pause does.

## 7. CLI flag grammar

```
mallorca [file] [--create-room | --join-room=<HASH>] [--room-name=<NAME>]
         [--nick=<NICK>] [--private] [--no-mdns] [--no-dht] [--no-relay]
         [--max-peers=<N>]
```

- `--create-room` / `--join-room=<HASH>` are mutually exclusive; every other
  room flag requires one of them to be present.
- The room hash is a bare base58 string (the mesh id itself — no URI wrapping).
- `mesh_open` (and therefore the room) must succeed **before** the window
  opens: on success the room hash prints to stdout (its own line, so it's
  easy to copy) along with a ready-to-paste `--join-room=` hint; on failure
  `mallorca` prints `mesh_last_error()` to stderr and exits — no window is ever
  created.
- Default `--nick` is `$USER-<4 lowercase hex>`.
- Rooms default to public/discoverable (`is_public=1`, `mdns=1`, `dht=1`,
  `relay=1`); `--private`, `--no-mdns`, `--no-dht`, `--no-relay` each flip one
  off. `--max-peers=N` caps HyParView neighbors / PeerInfo dials (default
  **64** when omitted or `0` — not unlimited). A mistaken small value (e.g.
  `--max-peers=2`) yields a 3-participant room.
- The old `--net-host`, `--net-spike`, `--headless`, and `--room=` flags are
  removed and hard-error with a hint to use `--create-room` / `--join-room`.

## 8. Edge cases

- **Join to a dead or mistyped room id:** `mesh_open` succeeds with 0 peers —
  indistinguishable at the mesh layer from "room exists, nobody's here yet."
  See the 15-second alone hint in §4.
- **Recv overflow:** frames are drained every frame at a 0 ms timeout;
  snapshots are idempotent full-grid state, so a dropped/overflowed frame
  self-heals on the next one.
- **Partial receive buffer from a peer that vanished mid-frame:** cleared when
  the roster poll drops that nickname (§4), not on a timeout — so a genuinely
  slow but still-present peer's partial buffer is never discarded early.
- **Grid resize mid-session:** every snapshot carries `w`/`h`; a receiver
  reallocates the peer's sim grid on a dimension change.
