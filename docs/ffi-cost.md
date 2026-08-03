# What the fofoca FFI costs

Mallorca links `fofoca` unconditionally — every `just check/build/release/bundle/test`
depends on the `fofoca` recipe, and `src/fofoca.odin` `foreign import`s a 221 MB static archive. Nothing
measured what that cost until now. This is that measurement.

Regenerate everything here with `just measure` (see [Method](#method)). Raw samples land in
`bin/measure/`.

Measured 2026-07-31 on a Mac17,2 (10 cores, 24 GB, macOS 27.0), Odin `dev-2026-07:819fdc7a8`,
rustc 1.95.0, at `fa15f0b`.

## Summary

The cost splits in two, and the split matters more than either number:

- **Everyone pays the size.** The mesh is linked into every build, so a user who never opens a room
  still ships **39.4 MiB** of iroh, tokio, automerge and rustls. That is **96.7%** of the binary.
- **Only jammers pay the runtime.** Linking the archive costs nothing measurable while
  `app.p2p_active` is false. Opening a room costs ~23 MB of RSS, 10 extra threads, and ~1.2 pp of CPU.

The runtime finding worth acting on is neither CPU nor RAM: **a joining peer's render thread blocks
for ~5 seconds**, once, on the first mesh call after the connection comes up. Because
`src/midi.odin` stamps CoreMIDI packets with "now" rather than scheduling ahead, that is a five-second
freeze of both the UI and the MIDI clock. It reproduced in 13 of 13 joining runs.

## Size

`-o:speed`, the configuration `just release` and `just bundle` ship.

| build                         |       bytes |                                  vs baseline |
| ----------------------------- | ----------: | -------------------------------------------: |
| with mesh                     |  42,699,056 |                                              |
| no-mesh baseline              |   1,398,032 |                                              |
| **delta**                     |             |                    **41,301,024 (39.4 MiB)** |
| with mesh, `strip -x`         |  32,999,496 |                                              |
| no-mesh, `strip -x`           |   1,349,448 |                                              |
| delta, stripped               |             |                        31,650,048 (30.2 MiB) |
| `Mallorca.app` bundle         |  42,876,928 | ~27× the 1.6 MB it would be without the mesh |
| `libfofoca_ffi.a` | 231,820,176 |               17.8% of it reaches the binary |

The archive's 221 MB headline is misleading — the linker pulls only referenced members, so quoting it
overstates the cost by 5.6×. 39.4 MiB is the honest number.

### Where the bytes go

| section                                            |        delta | note                                                 |
| -------------------------------------------------- | -----------: | ---------------------------------------------------- |
| `__TEXT/__text`                                    |   19,241,800 | code                                                 |
| `__TEXT/__eh_frame`                                |    3,641,336 | unwind tables                                        |
| `__TEXT/__gcc_except_tab`                          |    1,169,936 | landing pads                                         |
| `__TEXT/__const`                                   |    1,373,624 |                                                      |
| `__DATA_CONST/__const`                             |      978,464 | vtables, relocations                                 |
| `__TEXT/__unwind_info`                             |      657,080 |                                                      |
| `__TEXT/__cstring`                                 |      361,148 |                                                      |
| all other sections                                 |       99,980 |                                                      |
| _sum of `size -m` sections_                        | _27,523,368_ |                                                      |
| `__LINKEDIT` + padding (not itemized by `size -m`) |   13,777,656 | of which 9,650,976 is strippable symbol/string table |

**5.22 MiB — 13.2% of the delta — is panic-unwinding machinery** (`__eh_frame` + `__gcc_except_tab` +
`__unwind_info`). That is exactly what `panic = "abort"` would delete, and exactly what the FFI's
`catch_unwind` boundary currently requires. See [Reduction levers](#reduction-levers).

### Which dependency

Attributed from `__text` symbol address deltas (see [Method](#method)); sums to within 0.2% of the
measured `__text` delta.

| family                                | `__text` (MiB) |    share | does mallorca use it?                                         |
| ------------------------------------- | -------------: | -------: | ------------------------------------------------------------- |
| Rust core/alloc/std                   |           3.47 |    18.5% | unavoidable                                                   |
| tokio + futures                       |           2.15 |    11.5% | yes — the runtime the FFI blocks on                           |
| HTTP/relay stack (h2, hyper, reqwest) |           1.61 |     8.6% | only when relaying                                            |
| TLS + crypto (rustls, ring, dalek)    |           1.57 |     8.4% | yes                                                           |
| **automerge (CRDT)**                  |       **1.51** | **8.1%** | barely — one flat bpm/playing doc (`docs/p2p-protocol.md` §6) |
| iroh endpoint + transports            |           1.50 |     8.0% | yes — the core of it                                          |
| **DNS discovery (hickory, iroh-dns)** |       **0.91** | **4.8%** | only when resolving relay names                               |
| mesh engine + FFI shim                |           0.75 |     4.0% | yes                                                           |
| QUIC (noq)                            |           0.73 |     3.9% | yes                                                           |
| **tracing + regex (EnvFilter)**       |       **0.72** | **3.8%** | no — mallorca never sets a filter                             |
| **NAT traversal + DHT + mDNS**        |       **0.56** | **3.0%** | only with discovery on                                        |
| macOS objc2 bindings                  |           0.53 |     2.8% | yes                                                           |
| serde + json                          |           0.40 |     2.1% | yes                                                           |
| Odin: app + runtime + karl2d          |           0.40 |     2.1% | _present in both builds_                                      |
| everything else (200+ crates)         |           1.92 |    10.2% | mixed                                                         |

The mesh engine mallorca actually calls is 0.75 MiB. The other ~18 MiB is its dependency closure.
The bolded rows — automerge, DNS, tracing/regex, NAT/DHT — total **3.70 MiB of `__text`** and are
either unused or used only on paths mallorca can disable at runtime today (`--no-mdns --no-dht
--no-relay`) but cannot unlink.

### Reduction levers

Measured, not applied.

| lever                               |            saving | cost                                                                                                                                            |
| ----------------------------------- | ----------------: | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `strip -x` on release               |      **9.25 MiB** | separate dSYM for symbolication; `just release` doesn't strip today                                                                             |
| `-o:size` instead of `-o:speed`     |         496 bytes | none, and pointless — the flag doesn't reach the Rust code                                                                                      |
| `panic = "abort"`                   |     up to 5.2 MiB | **blocked**: every entry point in `ffi.rs` wraps in `catch_unwind`; a Rust panic would abort the app instead of surfacing via `mesh_last_error` |
| drop automerge                      | ~1.5 MiB `__text` | replace the transport CRDT with a plain LWW field; `docs/p2p-protocol.md` §6 only needs bpm + playing                                           |
| drop tracing-subscriber's EnvFilter | ~0.7 MiB `__text` | lose `RUST_LOG` filtering in the vendored engine                                                                                                |
| fat LTO + `codegen-units=1`         |      not measured | fofoca's `FORKED.md` records thin/16 as a deliberate dev-loop tradeoff; worth a one-off measurement before a release                |

`strip` is the only free one, and it is the largest. Everything else is a design decision.

The deeper answer is structural: the mesh engine's own code is 0.75 MiB of `__text` and the other
~18 MiB is its dependency closure, which no build flag can reach.
[mesh-slimming.md](https://github.com/fofoca-network/fofoca/blob/main/docs/mesh-slimming.md) root-causes each of the runtime numbers below and proposes a
crate split — modelled on p2panda — that would make the closure opt-in.

## CPU and RAM

Six scenarios, `--profile-run=60`, N=5 (N=8 for E), median across runs, IQR in the raw TSV.

| #   | scenario                                   |      %CPU |              RSS | threads |  frames/60s |
| --- | ------------------------------------------ | --------: | ---------------: | ------: | ----------: |
| A   | no-mesh build, no room                     |       6.0 |          84.9 MB |       7 |        4806 |
| B   | mesh linked, no room                       |       6.2 |          84.6 MB |       7 |        4822 |
| C   | room open, no peer                         |       7.4 |         107.5 MB |      17 |        6873 |
| D   | one peer, paused (host / join)             | 7.6 / 7.3 | 106.2 / 105.1 MB |      17 | 9843 / 6275 |
| E   | one peer, playing (host / join)            | 8.3 / 7.8 | 108.2 / 109.4 MB | 17 / 16 | 9841 / 6238 |
| F   | room open, `--no-mdns --no-dht --no-relay` |       7.2 |         108.6 MB |      17 |        6856 |

**B ≈ A** on every axis — the plan's sanity check. Linking 39 MB of Rust costs nothing at runtime as
long as no room is open; there are no static initializers doing work.

**Opening a room** (C vs B) costs **+1.2 pp CPU, +22.9 MB RSS, +10 threads**. The threads are the
`new_multi_thread` tokio runtime in `pipe.rs:304`, which sizes itself to `num_cpus` — 10 workers on
this 10-core machine, on top of a render loop that is strictly single-threaded. `vmmap` shows their
stacks adding 20 MB of reserved address space and ~1.5 MB resident. Physical footprint goes
203 MB → 221 MB.

**A connected peer adds almost nothing** over an open room: C → E-host is +0.9 pp CPU and +0.7 MB.
The snapshot traffic that `docs/p2p-protocol.md` budgets at ~1.5 KB × 8/s is not a measurable cost.

**Turning discovery off barely helps** (F vs C: 7.4 → 7.2 pp, inside the IQR). mDNS, DHT and relay
are not where the CPU goes.

### The per-frame tax

`p2p_poll` costs **~1.15 ms on every single frame** (mean 1146–1186 µs, p50 in the 1279 µs bucket,
p99 ~2 ms), _whether or not any peer is connected and whether or not there is anything to read_.
At the ~100 fps this machine runs, that is **~11% of wall clock spent asking a `mesh_recv` with
`timeout_ms = 0` whether anything is pending**.

It is not the data path — scenario C has no peers and pays it in full. It is the fixed cost of
`runtime.block_on` round-tripping from the render thread into the tokio runtime and back, once per
frame. `p2p_roster_tick` by contrast is genuinely cheap (p99 ≈ 1 µs, since 99 of 100 calls take the
1 Hz early return) and `p2p_send_own` is ~191 µs at p99.

Frame time itself (p50 10.2 ms with mesh, 12.3 ms without) is vsync-bound in every scenario and
should not be read as a work measurement; the difference is the display settling at a different
refresh, not the mesh making rendering faster.

### The join stall

**Every joining peer blocks its render thread for ~5 seconds, exactly once.** 13 of 13 runs:

| runs | scenario                                        | attributed to                         | measured                       |
| ---- | ----------------------------------------------- | ------------------------------------- | ------------------------------ |
| 5    | D-join (paused)                                 | `p2p_roster_tick`                     | 4.80, 4.92, 4.93, 4.94, 5.05 s |
| 5    | E-join (playing)                                | frame body; site not yet instrumented | 4.98, 5.05, 5.07, 5.31, 5.38 s |
| 3    | E-join, re-run with `p2p_send_own` instrumented | `p2p_send_own` → `mesh_send`          | 4.96, 4.99, 5.04 s             |

The third row is why the second exists: the first pass showed the stall in `frame` but not in
`p2p_poll` or `p2p_roster_tick`, so a span was added around `p2p_send_own` and scenario E re-run.

It is not specific to either call. Whichever mesh call the joining peer makes first after the
connection is established absorbs the block — `mesh_send` when the clock is running (a tick fires
first), the roster's `mesh_peers_json`/`mesh_state_json` when paused. The host never sees it: its
worst `p2p_roster_tick` is 3.4 ms and its worst `mesh_send` 650 µs. The consistency of the figure
(4.80–5.38 s across all 13 runs and both call sites) points at a 5-second timeout somewhere in the
mesh/iroh join path rather than at variable work.

Consequences, given the architecture:

- The window is frozen — `k2.present()` is not reached for 5 s.
- `update_sim` drops every tick that falls in the gap. At 120 BPM that is ~40 ticks; `src/main.odin`
  deliberately preserves phase (`app.accum = math.mod(...)`) and drops the overdue ticks, so notes
  are lost rather than bunched.
- Any note sustained at that moment stays on for 5 s, since `advance_notes` never runs.

This is the one measurement here that argues for a code change rather than a note in a doc.

## Method

`scripts/measure-ffi-cost.sh` (`just measure [size|runtime|all]`). It never modifies the repo.

**Size baseline.** `src/` is copied to `bin/measure/work/src-nomesh/` and `mesh.odin` is replaced by
a generated stub with the identical surface — same types, same proc names, same signatures, same
helpers — implemented in plain Odin with no `foreign import`. `p2p.odin` and `main.odin` are copied
verbatim and compile unchanged, so the only difference between the two binaries is the Rust archive
and what the linker pulls from it. If `mesh.odin` gains or changes a symbol, the baseline fails to
compile rather than silently measuring the wrong thing.

**Attribution.** `bloaty` if installed, otherwise `nm -n` address deltas: a symbol's size is the gap
to the next one, names are demangled with `c++filt`, and the bucket is the first non-`core`/`alloc`/
`std` crate in the demangled path — so `core::ptr::drop_in_place<rustls::…>` is charged to rustls,
not to core. Odin symbols are separated by mangling shape. Unattributed residue is 3.0%.

**Instrumentation.** `-define:MALLORCA_PROFILE=true` (`just profile`) compiles in `src/profile.odin`:
log-scale histograms with 4 sub-buckets per octave (~19% worst-case percentile error) around the
frame loop, `p2p_poll`, `p2p_roster_tick`, `p2p_send_own`, `p2p_open`, and exec→window. Reported
percentiles are bucket _upper_ bounds. The first 2 s after the window appears are skipped: font
baking and window-server settling produce ~500 ms outliers that appear identically in the no-mesh
build. `--profile-run=<seconds>` plays from the first frame, runs for a fixed wall-clock window,
dumps TSV, and exits through the normal defer chain; `--profile-no-play` leaves the clock stopped.

The shipping build is unaffected: every declaration and call site sits inside `when
MALLORCA_PROFILE`, and a `-o:speed` build before and after the change has **byte-identical `size -m`
sections, an identical symbol set, and zero `prof` symbols**. Note that byte-identity of the _file_
is not achievable and was not the check — two builds of unmodified source already differ in 27,315
bytes, because Odin emits a per-build counter suffix on anonymous statics.

**Sampling.** `ps` at 1 Hz for RSS/VSZ/threads; CPU% is derived from the cumulative `ps time` delta
rather than the `%cpu` column, which on a vsync-locked loop mostly reports the display refresh rate.
`footprint` and `vmmap -summary` are captured once at 80% through each run. Paired scenarios launch
the host, parse its bare room hash from stdout, launch the joiner, and sample both; the host outlives
the joiner so it exits on its own deadline and gets to dump its histograms.

### Caveats

- One machine, one display, one session. The absolute %CPU is not portable; the A↔B↔C deltas are the
  transferable part.
- Both windows in a paired scenario open at the same default position, so the host is partly occluded
  by the joiner. Host CPU is therefore a lower bound. It is nonetheless consistently _higher_ than the
  joiner's, because the joiner spends 5 of its 60 s blocked.
- `VSZ` is not reported: it is ~466 GB in every scenario, including the no-mesh baseline, and carries
  no signal on macOS.
- The `frame_max` of ~0.5 s that appears in _every_ scenario, including no-mesh, is not the mesh. It
  survives the 2 s warm-up skip and has not been chased down.

## See also

- [`docs/p2p-protocol.md`](p2p-protocol.md) — the wire protocol and its bandwidth budget
- [`FORKED.md`](https://github.com/fofoca-network/fofoca/blob/main/FORKED.md) in the fofoca repo — fork provenance and the
  deliberate thin-LTO / no-`panic=abort` choices
- [`mesh-slimming.md`](https://github.com/fofoca-network/fofoca/blob/main/docs/mesh-slimming.md) — the crate split these
  measurements motivated (it used to live here)
- `src/profile.odin`, `scripts/measure-ffi-cost.sh`
