// Optional timing instrumentation, compiled in only with
// -define:MALLORCA_PROFILE=true. Off by default, and everything below —
// including the call sites in main.odin — sits inside `when MALLORCA_PROFILE`,
// so a normal build is byte-identical to one from before this file existed.
//
// It exists because the mesh FFI's runtime cost lands on the render thread:
// p2p_poll and p2p_roster_tick run inline in the frame loop, and midi.odin
// stamps CoreMIDI packets with "now" rather than scheduling ahead, so frame
// jitter is MIDI jitter. Aggregate %cpu can't see that; a frame-time tail can.
// See docs/ffi-cost.md.
package main

import "base:intrinsics"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

MALLORCA_PROFILE :: #config(MALLORCA_PROFILE, false)

when MALLORCA_PROFILE {

	// Histogram over microseconds with 4 sub-buckets per octave, i.e. ~19%
	// worst-case error on a reported percentile. Plain log2 buckets would be
	// a factor of 2 out, which is too coarse to tell an 8.3 ms frame (120 Hz)
	// from a 16.7 ms one (60 Hz).
	PROF_OCTAVES :: 32 // up to ~2^32 µs ≈ 71 minutes
	PROF_BUCKETS :: PROF_OCTAVES * 4

	Prof_Hist :: struct {
		count:    u64,
		total_us: u64,
		max_us:   u64,
		buckets:  [PROF_BUCKETS]u64,
	}

	// The three spans on the render thread. prof_frame is the whole loop body
	// including present(); the other two are the mesh calls inside it.
	prof_frame: Prof_Hist
	prof_poll: Prof_Hist
	prof_roster: Prof_Hist
	// p2p_send_own -> fofoca_send, called from update_sim once per tick. Also a
	// blocking round trip into the tokio runtime, so it belongs in the tail.
	prof_send: Prof_Hist

	// One-shot startup spans (microseconds).
	prof_open_us: u64 // p2p_open: fofoca_open + discovery
	prof_init_us: u64 // process start -> k2.init returned (window on screen)

	prof_boot: time.Tick // set first thing in main

	// --profile-run=<seconds>: start playing immediately, run for this long,
	// dump, and quit through the normal defer chain. Without it a CPU sample
	// would need a human to press Space and a kill(1) to stop, and "playing"
	// scenarios would not be reproducible.
	prof_run_seconds: f64
	prof_run_start: time.Tick

	// --profile-no-play: run the fixed window without starting the clock, so a
	// paused scenario can be compared against a playing one.
	prof_no_play: bool

	// Clock helpers, so main.odin's call sites never have to name a `time`
	// type and therefore never need the import — keeping the non-profile
	// build textually identical to before.
	prof_now :: proc "contextless" () -> time.Tick {
		return time.tick_now()
	}

	prof_since :: proc "contextless" (t: time.Tick) -> time.Duration {
		return time.tick_since(t)
	}

	prof_us_since :: proc "contextless" (t: time.Tick) -> u64 {
		return u64(max(i64(time.tick_since(t)), 0) / 1000)
	}

	// Bucket index for a microsecond value: octave*4 + the two bits below the
	// leading one. Values under 4 get their own exact buckets (0..3); 4..7 are
	// left unused so the formula needs no special case above that.
	prof_bucket :: proc "contextless" (us: u64) -> int {
		if us < 4 {
			return int(us)
		}
		oct := 63 - int(intrinsics.count_leading_zeros(us))
		sub := int((us >> uint(oct - 2)) & 3)
		idx := oct * 4 + sub
		if idx >= PROF_BUCKETS {
			return PROF_BUCKETS - 1
		}
		return idx
	}

	// Upper bound of a bucket, used as the (conservative) percentile estimate.
	prof_bucket_hi :: proc "contextless" (idx: int) -> u64 {
		if idx < 4 {
			return u64(idx)
		}
		oct := uint(idx / 4)
		sub := u64(idx % 4)
		return ((4 + sub + 1) << (oct - 2)) - 1
	}

	// The first frames after the window appears are dominated by font baking
	// and the window server settling — half-second outliers that show up
	// identically in the no-mesh build and would otherwise own every `max`
	// column. Skip them so the tail actually reflects steady state.
	PROF_WARMUP_SECONDS :: 2.0

	prof_warm :: proc "contextless" () -> bool {
		return time.duration_seconds(time.tick_since(prof_run_start)) >= PROF_WARMUP_SECONDS
	}

	prof_record :: proc "contextless" (h: ^Prof_Hist, d: time.Duration) {
		if !prof_warm() {
			return
		}
		us := u64(max(i64(d), 0) / 1000)
		h.count += 1
		h.total_us += us
		if us > h.max_us {
			h.max_us = us
		}
		h.buckets[prof_bucket(us)] += 1
	}

	// Smallest bucket upper bound at or above the p-th percentile.
	prof_pct :: proc "contextless" (h: ^Prof_Hist, p: f64) -> u64 {
		if h.count == 0 {
			return 0
		}
		want := u64(f64(h.count) * p)
		if want == 0 {
			want = 1
		}
		seen: u64
		for n, i in h.buckets {
			seen += n
			if seen >= want {
				return prof_bucket_hi(i)
			}
		}
		return h.max_us
	}

	// TSV on stdout. `prof` lines are histograms, `profv` lines are scalars;
	// scripts/measure-ffi-cost.sh greps for both.
	prof_dump :: proc() {
		fmt.println("prof\tname\tcount\tmean_us\tp50_us\tp95_us\tp99_us\tmax_us")
		prof_report("frame", &prof_frame)
		prof_report("p2p_poll", &prof_poll)
		prof_report("p2p_roster_tick", &prof_roster)
		prof_report("p2p_send_own", &prof_send)
		fmt.printfln("profv\tp2p_open_us\t%d", prof_open_us)
		fmt.printfln("profv\twindow_up_us\t%d", prof_init_us)
		fmt.printfln(
			"profv\trun_seconds\t%.3f",
			time.duration_seconds(time.tick_since(prof_run_start)),
		)
	}

	@(private = "file")
	prof_report :: proc(name: string, h: ^Prof_Hist) {
		mean: u64
		if h.count > 0 {
			mean = h.total_us / h.count
		}
		fmt.printfln(
			"prof\t%s\t%d\t%d\t%d\t%d\t%d\t%d",
			name,
			h.count,
			mean,
			prof_pct(h, 0.50),
			prof_pct(h, 0.95),
			prof_pct(h, 0.99),
			h.max_us,
		)
	}

	// Returns true if the arg was a profiling flag and has been consumed, so
	// the caller can skip it. A malformed value exits rather than falling
	// through to be misread as a filename.
	prof_parse_arg :: proc(arg: string) -> bool {
		if arg == "--profile-no-play" {
			prof_no_play = true
			return true
		}
		if !strings.has_prefix(arg, "--profile-run=") {
			return false
		}
		secs, ok := strconv.parse_f64(arg[len("--profile-run="):])
		if !ok || secs <= 0 {
			fmt.eprintfln("mallorca: invalid --profile-run value %q", arg)
			os.exit(1)
		}
		prof_run_seconds = secs
		return true
	}

	prof_run_expired :: proc() -> bool {
		if prof_run_seconds <= 0 {
			return false
		}
		return time.duration_seconds(time.tick_since(prof_run_start)) >= prof_run_seconds
	}
}
