# M6 network protocol

**Live.** This is the wire protocol for the relay transport: the Phoenix server
in `server/` and the host↔server TCP link that `--net-host` dials. It runs
alongside, not instead of, the serverless mesh in
[p2p-protocol.md](p2p-protocol.md); a session uses one or the other, never
both. The `snapshot` grid encoding in §2 (row-major string, `.` empty, no
separators) is shared by both protocols.

---

Wire protocol for mallorca's network mode (PLAN.md → M6). This is the contract
both sides implement; write it before coding either.

Status: **draft**. The message *schema* here is transport-agnostic; the
host↔server *transport* is a recommendation (§3) still open for final
ratification.

## 1. Model recap

- The **host** (H) is the one native mallorca instance. It is authoritative:
  it holds a VM + grid per participant, runs the single clock, and emits all
  MIDI. It never receives MIDI; it receives *edits* and emits *snapshots*.
- The **server** (S) is Phoenix. It is a relay + presence + persistence + UI.
  It does **not** run Orca.
- A **browser player** (B) live-codes in a LiveView editor. 0..N of them. A
  browser is a thin editor/viewer: it sends edits and renders snapshots.
- A **room** groups one host and its players, keyed by a short **room code**.
  One host serves one room. The host's own grid is a participant too.

```
        edits                       edits
  B ───────────────▶ S ───────────────────▶ H   (browser → server → host)
  B ◀─────────────── S ◀─────────────────── H   (host → server → browser)
        snapshots                   snapshots
   LiveView / Channels          TCP / NDJSON (§3)
```

## 2. Parties, links, identifiers

| Link | Parties | Transport | Framing |
| --- | --- | --- | --- |
| Control/real-time | H ↔ S | TCP (recommended, §3) | newline-delimited JSON |
| Editor/UI | B ↔ S | Phoenix LiveView (WebSocket) | LiveView events + Presence |

**Identifiers**
- `room` — room code. Short, unambiguous base32, 6 chars (no `0/O/1/I`).
  Server-assigned at host `hello` (or host may request one).
- `pid` — player id, server-assigned, unique within a room, stable for a
  session. `pid: "host"` is reserved for the host's own grid.
- `token` — opaque per-player secret returned on join; a browser stores it and
  presents it on rejoin to reclaim its `pid` + persisted grid (see §7 resume).
- `v` — protocol version integer; sent in `hello`. Major mismatch ⇒ `error`.

**Coordinates & grid encoding**
- `x` = column (0-based, left→right); `y` = row (0-based, top→bottom).
- `grid` = a single string of length `w*h`, row-major, `.` for empty. No
  separators; dimensions come from `w`,`h`.
- `marks` = hex string, length `2*w*h`, one byte (2 hex chars) per cell,
  row-major, encoding the `core` Mark bitset (locked/sleep/haste/input/output).
  All-zero cells stay `00`. (For large grids a sparse `[[x,y,flags],…]` form is
  allowed; M6 uses the dense hex form — grids are small.)

## 3. Transport (host ↔ server)

**Recommended: line-delimited JSON over TCP.** The host opens one long-lived TCP
connection to the server (default port `4001`, configurable). Each message is
one JSON object on a single line terminated by `\n`; JSON string escaping keeps
payloads newline-free. A message-size sanity cap (e.g. 1 MiB) guards against
runaway frames. The host reconnects with backoff on drop.

Rationale: trivial with Odin's `core:net`; no WebSocket/Channels client to
hand-roll in Odin; browsers still use native LiveView. The alternative — a
hand-rolled WS client in Odin speaking the Phoenix Channels join/heartbeat
protocol — unifies the transport but adds RFC 6455 handshake + framing + channel
plumbing on the Odin side. The message schema below is identical either way.

Heartbeat: `ping`/`pong` every ~15 s both directions; used for liveness and RTT
(latency shown on the dashboard).

## 4. Message envelope

Every message is a flat JSON object with a `t` (type) field. Other fields are
type-specific. Unknown fields are ignored (forward-compatible). Unknown `t` is
logged and dropped, never fatal.

```json
{ "t": "edit", "pid": "a1b2c3", "x": 3, "y": 1, "g": "D" }
```

## 5. Message catalog

### 5.1 Host ↔ server control

| `t` | Dir | Fields | Meaning |
| --- | --- | --- | --- |
| `hello` | H→S | `v`, `role:"host"`, `room?`, `name`, `auth?`, `resume?` | Host announces itself; `room` requests/reclaims a code, `resume:true` reclaims after a crash. `auth` is the shared host secret. |
| `welcome` | S→H | `room`, `bpm`, `playing`, `players:[{pid,name}]`, `snapshots?:[{pid,w,h,grid,tick}]` | Server accepts; on resume, `players`+`snapshots` let the host rehydrate every VM. |
| `error` | S→H | `code`, `msg` | e.g. `version_mismatch`, `host_taken`, `bad_auth`. Usually fatal for that connection. |
| `ping`/`pong` | both | `ts` | Liveness + RTT. Echo `ts` back in `pong`. |
| `bye` | both | `reason?` | Graceful shutdown. |

### 5.2 Player lifecycle (server → host)

| `t` | Fields | Meaning |
| --- | --- | --- |
| `player_join` | `pid`, `name`, `resume?` | A browser joined. Host allocates a VM/grid for `pid` (blank, or from a persisted snapshot if `resume`). |
| `player_leave` | `pid` | Browser left/disconnected. Host drops the grid and flushes that player's sustained MIDI notes. |

### 5.3 Editing (server → host)

The browser is not authoritative; edits are *requests* the host applies between
ticks (single-writer, see PLAN.md). Cursor position is **not** sent to the host
in M6 (host doesn't need it to simulate; cursor sharing is M8).

| `t` | Fields | Meaning |
| --- | --- | --- |
| `edit` | `pid`, `x`, `y`, `g` | Write glyph `g` (a 1-char string; `.` clears) at `(x,y)` in `pid`'s grid. |
| `paste` | `pid`, `x`, `y`, `w`, `h`, `cells` | Write a `w×h` block (row-major string `cells`) with top-left at `(x,y)`, clipped to the grid. |
| `resize` | `pid`, `w`, `h` | Resize `pid`'s grid (host reallocates, preserving overlap). |

### 5.4 Simulation output (host → server)

| `t` | Fields | Meaning |
| --- | --- | --- |
| `snapshot` | `pid`, `w`, `h`, `grid`, `marks`, `tick` | The evaluated grid + marks for `pid` after a tick (or after an edit while paused). Server pushes it to `pid`'s LiveView and persists it (§8). |

Cadence: while **playing**, at most one snapshot per player per tick
(~8/s at 120 BPM ÷ 4 frames/beat), sent only when the grid or marks changed.
While **paused**, one snapshot per applied edit (preview highlighting), coalesced.

### 5.5 Transport (play/pause/tempo)

The host owns tempo; the dashboard/players send *requests*.

| `t` | Dir | Fields | Meaning |
| --- | --- | --- | --- |
| `transport` | S→H | `playing?`, `bpm?` | Request a transport change (from the dashboard). |
| `transport` | H→S | `playing`, `bpm`, `tick` | Authoritative state echo after the host applies it; server fans out to all views. |

### 5.6 Deferred to M8 (listed for completeness, not implemented in M6)

`cursor` (player cursor position broadcast), `grid_broadcast` (a player's
snapshot fanned out to *other* players, not just the dashboard), and
richer presence (playing vs. spectating). Reserve these `t` values now.

## 6. Browser ↔ server (LiveView)

Browser traffic rides LiveView; it mirrors the host schema but as LiveView
events/pushes rather than TCP lines. The server translates:

- **join**: LiveView `mount` with `room` + `name` (+ stored `token` on rejoin) ⇒
  server assigns/reclaims `pid`, tracks `Phoenix.Presence`, and sends the host a
  `player_join`. Server returns `{pid, token}` to the browser.
- **edit / paste / resize** (B→S event) ⇒ forwarded verbatim to H (with `pid`).
- **snapshot** (H→S) ⇒ `push` to that `pid`'s LiveView to render.
- **transport** (dashboard event) ⇒ forwarded to H; H's echo fans out to all.
- **presence** ⇒ `Phoenix.Presence` diffs drive the room roster in every view.

## 7. Flows

**Startup.** H connects → `hello` → S replies `welcome`. B opens the LiveView →
join → S assigns `pid`, tracks presence, sends H `player_join` → H creates a
blank grid for `pid` → H begins sending `snapshot`s for `pid` → B renders.

**Edit loop.** B types → `edit`(B→S) → S forwards `edit`(S→H) → H applies it
between ticks → next tick H simulates → `snapshot`(H→S) → S pushes to B → B
renders. The browser shows the keystroke immediately (optimistic echo) and the
next snapshot reconciles it.

**Transport.** Dashboard toggles play → `transport`(→S→H) → H applies, emits
MIDI accordingly, echoes `transport`(H→S) → S fans out → all views update.

**Crash / resume.**
- *Host process dies:* S keeps room state in memory (and SQLite). Players see
  "host offline". On restart, H sends `hello{resume:true, room, auth}`; S replies
  `welcome` with `players` + persisted `snapshots`; H rehydrates each VM from the
  latest grid + `tick` and resumes. This works even with no DB as long as S
  stayed up (in-memory snapshots).
- *Server restarts (or both crash):* S reloads rooms/players/snapshots from
  SQLite on boot; H reconnects via `resume`; browsers rejoin by `room` + `token`.
- *Browser disconnects:* S fires `player_leave` to H after a grace period; the
  player's grid persists (SQLite) and is reclaimed on rejoin via `token`.

## 8. Persistence (SQLite via Ecto)

Written on edit (debounced ~1 s) + periodic checkpoint (~5 s) + on
`player_leave`/`bye` — **not** every tick.

| Table | Columns (sketch) | Notes |
| --- | --- | --- |
| `rooms` | `code` (pk), `host_name`, `bpm`, `playing`, `inserted_at`, `updated_at` | One per room. |
| `players` | `pid` (pk), `room_code` (fk), `name`, `token_hash`, `last_seen` | `token_hash` gates rejoin. |
| `grid_snapshots` | `pid` (fk), `w`, `h`, `grid`, `marks?`, `tick`, `updated_at` | Latest per player (upsert). |

Optional later: an append-only `snapshot_history` for admin scrubbing/replay
(explicitly out of M6 scope).

## 9. Errors & edge cases

- **Two hosts, one room:** second `hello` without a valid `resume`+`auth` ⇒
  `error{host_taken}`. With valid `resume`+`auth`, it's a takeover.
- **Edit for unknown `pid`:** S drops + logs (player already left).
- **Malformed line / oversize frame (H↔S):** log; may close the connection.
- **Version mismatch:** `error{version_mismatch}`; host must upgrade.
- **Bad/absent host auth:** `error{bad_auth}`.

## 10. Security (M6 scope)

Assume a LAN or trusted VPN (per PLAN.md). Room code is a soft secret; the host
link requires a shared `auth` secret (server config); the admin dashboard sits
behind a shared token / basic auth. No per-user accounts in M6.

## 11. M6 minimal subset vs. later

Required for the M6 deliverable (one remote player live-codes, host sounds it,
dashboard shows grids): `hello`/`welcome`/`error`, `ping`/`pong`,
`player_join`/`player_leave`, `edit`, `snapshot`, `transport`, LiveView
join/render, and the three SQLite tables.

Deferred: `paste`/`resize` (nice-to-have), `cursor`/`grid_broadcast` (M8),
`snapshot_history` (later), rich auth.

## 12. Open questions

1. Snapshot diffing: full grid every tick (start here, grids are tiny) vs.
   dirty-cell deltas once bandwidth matters.
2. Marks fidelity: which Mark flags the browser actually needs for coloring
   (probably locked/output/input) — trim the hex payload accordingly.
3. Host `auth`: static shared secret (M6) vs. per-session handshake later.
4. Room lifecycle: does a room persist after the host disconnects, and for how
   long, before its SQLite rows are reaped?
