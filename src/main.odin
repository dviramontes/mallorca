// mallorca — native Odin port of Orca.
// Grid display + editing + running simulation, with the VM's MIDI events
// delivered via CoreMIDI (see midi.odin). OSC and UDP remain deferred.
package main


import k2 "../karl2d"// macOS-only for now; gate with #+build when porting
import orca "core"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import NS "core:sys/darwin/Foundation"

FONT_DATA :: #load("../assets/JetBrainsMono-Regular.ttf")
// Italic face, used only for the M10 hover readout (see draw_hover_readout).
FONT_ITALIC_DATA :: #load("../assets/JetBrainsMono-Italic.ttf")

// Font size used only to compute the initial window dimensions; after
// that, the grid scales to fill the window width.
INITIAL_FONT_SIZE :: 32

// Play-state border: a solid frame inset from the window edges; green
// while playing, absent while paused.
BORDER_INSET :: 10
BORDER_THICKNESS :: 3

// Content inset from window edges; leaves room for the border.
MARGIN :: 24

// JetBrains Mono has an advance of exactly 0.6 em; 1.15 em line height
// keeps the glyphs filling most of the cell.
ADVANCE_EM :: 0.6
LINE_EM :: 1.15

RULER_SPACING :: 8

// Cursor blink: shown for this many seconds, then hidden for the same, so a
// full cycle is 2×. ~0.53s matches the common editor blink rate.
BLINK_INTERVAL :: 0.53

// The status line renders at this fraction of the grid glyph size — it's
// heads-up/debug text, secondary to the grid.
STATUS_SCALE :: 0.6

// Orca-ish theme.
BG :: k2.Color{0x17, 0x17, 0x17, 0xff}
FG :: k2.Color{0xf0, 0xf0, 0xf0, 0xff}
DIM :: k2.Color{0x50, 0x50, 0x50, 0xff}
RULER :: k2.Color{0x88, 0x88, 0x88, 0xff}
STATUS :: k2.Color{0xb0, 0xb0, 0xb0, 0xff}
SECONDARY :: k2.Color{0xe3, 0x7f, 0x9a, 0xff} // pink; matches web text-secondary
CURSOR_BG :: SECONDARY
CURSOR_FG :: k2.Color{0x17, 0x17, 0x17, 0xff}

// Mark highlighting (per-tick sim scratch, see core/marks.odin).
OUTPUT_BG :: k2.Color{0xf0, 0xf0, 0xf0, 0xff} // freshly written cells, inverted
OUTPUT_FG :: k2.Color{0x17, 0x17, 0x17, 0xff}
INPUT :: k2.Color{0x6b, 0xd9, 0xd9, 0xff} // cyan-ish: operand cells
HASTE :: k2.Color{0x3f, 0x9d, 0x9d, 0xff} // darker cyan: hasted operands
LOCKED :: k2.Color{0x70, 0x70, 0x70, 0xff} // comment/data cells
PROJECTED :: k2.Color{224, 191, 100, 230} // Orca yellow at 90% alpha
PROJECTED_BORDER_THICKNESS :: f32(2)

PLAY_BORDER :: k2.Color{0x5d, 0xd0, 0x5d, 0xff} // green frame while playing

// M9 connection indicator (host mode).
CONN_OK :: k2.Color{0x3c, 0xb0, 0x43, 0xff} // connected: green
CONN_BAD :: k2.Color{0xc0, 0x3a, 0x3a, 0xff} // disconnected: red
CONN_WAIT :: k2.Color{0xc8, 0x9b, 0x3c, 0xff} // connecting: amber
SELECT :: k2.Color{0x2c, 0x3e, 0x63, 0xff} // muted blue behind selected cells

// Remote-view glyph palette (M8): when the host window shows a remote player's
// grid, its input renders in one of these so it reads as "not the host's white,
// and not that other player." Marks (input/output/etc.) still override per cell.
REMOTE_TINTS :: [?]k2.Color {
	{0xe6, 0x9a, 0x4c, 0xff}, // orange
	{0xa7, 0x8b, 0xde, 0xff}, // violet
	{0x6c, 0xc2, 0x77, 0xff}, // green
	{0xe0, 0x78, 0xa8, 0xff}, // pink
	{0xd9, 0xc0, 0x4a, 0xff}, // gold
	{0xd6, 0x6b, 0x5e, 0xff}, // coral
}

DEFAULT_W :: 57
DEFAULT_H :: 25

DEFAULT_FILE_NAME :: "untitled.orca"

DEFAULT_BPM :: 120
BPM_MIN :: 10
BPM_MAX :: 300

App :: struct {
	grid:         orca.Grid,
	file_name:    string,
	cursor_x:     int,
	cursor_y:     int,
	status_msg:   string, // transient message shown in the status bar
	status_timer: f32,
	repeat:       [len(REPEAT_KEYS)]f32,
	insert_mode:  bool, // typing advances the cursor when true
	audition:     bool, // Enter held: sounding the middle-C audition tone
	debug:        bool, // --debug: log edit/selection/clipboard activity
	show_guide:   bool, // Ctrl/Cmd+G operator overview

	// Cursor blink: `blink` accumulates seconds and toggles visibility every
	// BLINK_INTERVAL; movement resets it so the cursor is always shown while
	// you're navigating or typing.
	blink:        f32,
	blink_x:      int,
	blink_y:      int,

	// Rectangular selection: anchored at (sel_x, sel_y), extended to the
	// cursor. Inactive selections are treated as the single cursor cell.
	sel_active:   bool,
	sel_x:        int,
	sel_y:        int,

	// Clipboard: a rectangular block of glyphs (heap-owned).
	clip_cells:   []u8,
	clip_w:       int,
	clip_h:       int,

	// Undo history: full grid + cursor snapshots, pushed before each edit.
	undo:         [dynamic]Undo_Snapshot,

	// Simulation state.
	marks:        []orca.Mark,
	events:       [dynamic]orca.Event, // produced each tick, dispatched to MIDI
	tick:         uint,
	bpm:          int,
	playing:      bool,
	accum:        f32, // elapsed seconds not yet consumed by ticks
	dirty:        bool, // grid edited while paused; marks need a preview

	// MIDI output (M5).
	midi:         Midi,
	sus:          [dynamic]Sus_Note, // notes awaiting their note-off

	// P2P room (replaces the old Phoenix host/net link): peers stream full-grid
	// snapshots directly over the mesh; `p2p.status` drives the connection
	// indicator. See mesh.odin/p2p.odin.
	p2p:          P2p_State,
	p2p_active:   bool,

	// Remote view: which grid the window shows. HOST_VIEW is our own
	// (editable) grid; any other value is the remote peer carrying that tint,
	// shown read-only. Cycled with the '`' key.
	view_tint:    int,
}

// A grid + cursor snapshot for undo. Owns its own copy of the cells.
Undo_Snapshot :: struct {
	cells:    []u8,
	width:    int,
	height:   int,
	cursor_x: int,
	cursor_y: int,
}

// Cap on retained undo steps; oldest are dropped past this.
UNDO_MAX :: 128

// A note-on awaiting its note-off, counted down in VM frames (the note's
// duration). Tick-driven, matching orca-c, so tempo changes stay in sync.
Sus_Note :: struct {
	channel: u8,
	note:    u8, // final MIDI note number, 0-127
	frames:  int,
}

// Four VM frames per beat — orca-c's timing rule. The single source of
// truth for tick length (M5 note scheduling must reuse this).
frame_seconds :: proc(bpm: int) -> f32 {
	return 60.0 / f32(bpm) / 4.0
}

// Default p2p nickname when --nick isn't given: $USER-<4 lowercase hex>.
@(private = "file")
default_nick :: proc() -> string {
	user := os.get_env("USER", context.temp_allocator)
	if user == "" {
		user = "player"
	}
	hex := "0123456789abcdef"
	suffix: [4]u8
	for i in 0 ..< 4 {
		suffix[i] = hex[rand.int_max(16)]
	}
	return fmt.tprintf("%s-%s", user, string(suffix[:]))
}

main :: proc() {
	app: App

	// Args: an optional .orca file path, an optional --debug flag, and the p2p
	// room flags below, in any order. The first non-flag argument is the file.
	//
	//   [--create-room | --join-room=<HASH>] [--room-name=<NAME>] [--nick=<NICK>]
	//   [--private] [--no-mdns] [--no-dht] [--no-relay] [--max-peers=<N>]
	debug := false
	cli: P2p_Cli_Opts
	has_create := false
	has_join := false
	room_flag_seen := false
	nick_set := false

	for arg in os.args[1:] {
		switch {
		case arg == "--debug":
			debug = true
		case arg == "--create-room":
			has_create = true
		case strings.has_prefix(arg, "--join-room="):
			has_join = true
			cli.join_hash = arg[len("--join-room="):]
		case strings.has_prefix(arg, "--room-name="):
			cli.room_name = arg[len("--room-name="):]
			room_flag_seen = true
		case strings.has_prefix(arg, "--nick="):
			cli.nick = arg[len("--nick="):]
			nick_set = true
			room_flag_seen = true
		case arg == "--private":
			cli.private = true
			room_flag_seen = true
		case arg == "--no-mdns":
			cli.no_mdns = true
			room_flag_seen = true
		case arg == "--no-dht":
			cli.no_dht = true
			room_flag_seen = true
		case arg == "--no-relay":
			cli.no_relay = true
			room_flag_seen = true
		case strings.has_prefix(arg, "--max-peers="):
			n, ok := strconv.parse_int(arg[len("--max-peers="):])
			if !ok || n < 0 {
				fmt.eprintfln("mallorca: invalid --max-peers value %q", arg)
				os.exit(1)
			}
			cli.max_peers = n
			room_flag_seen = true
		case arg == "--net-host" || arg == "--net-spike" || arg == "--headless":
			fmt.eprintfln("mallorca: %s was removed — use --create-room / --join-room", arg)
			os.exit(1)
		case strings.has_prefix(arg, "--room="):
			fmt.eprintln("mallorca: --room was removed — use --create-room / --join-room")
			os.exit(1)
		case arg != "" && app.file_name == "":
			app.file_name = arg
		}
	}

	if has_create && has_join {
		fmt.eprintln("mallorca: --create-room and --join-room are mutually exclusive")
		os.exit(1)
	}
	p2p_requested := has_create || has_join
	if !p2p_requested && room_flag_seen {
		fmt.eprintln("mallorca: room flags require --create-room or --join-room")
		os.exit(1)
	}
	if !nick_set {
		cli.nick = default_nick()
	}

	app.debug = debug

	// p2p_open must succeed (or fail) before the window opens: on success the
	// full room hash is on stdout for a peer to join with; on failure the app
	// exits without ever creating a window.
	if p2p_requested {
		st, ok := p2p_open(cli)
		if !ok {
			fmt.eprintfln("mesh: %s", mesh_last_error_string())
			os.exit(1)
		}
		app.p2p = st
		app.p2p_active = true
		app.view_tint = HOST_VIEW
	}

	if app.file_name != "" {
		data, read_err := os.read_entire_file_from_path(app.file_name, context.allocator)
		if read_err != nil {
			fmt.eprintfln("mallorca: cannot read %q: %v", app.file_name, read_err)
			if app.p2p_active {
				p2p_shutdown(&app.p2p)
			}
			os.exit(1)
		}
		g, err := orca.parse_field(data)
		delete(data)
		if err != .None {
			fmt.eprintfln("mallorca: failed to load %q: %v", app.file_name, err)
			if app.p2p_active {
				p2p_shutdown(&app.p2p)
			}
			os.exit(1)
		}
		app.grid = g
	} else {
		app.grid = orca.make_grid(DEFAULT_W, DEFAULT_H)
	}
	app.marks = orca.make_marks(app.grid)
	app.bpm = DEFAULT_BPM
	app.dirty = true // preview marks for the freshly loaded grid
	app.midi = midi_init(debug)

	defer orca.destroy_grid(&app.grid)
	defer delete(app.marks)
	defer delete(app.events)
	defer delete(app.clip_cells)
	defer delete(app.sus)
	defer clear_undo(&app)
	defer midi_shutdown(&app.midi)
	defer if app.p2p_active {
		p2p_shutdown(&app.p2p)
	}
	defer if app.status_msg != "" {
		delete(app.status_msg)
	}

	window_w := MARGIN * 2 + app.grid.width * (INITIAL_FONT_SIZE * 3 / 5)
	window_h :=
		MARGIN * 2 + app.grid.height * (INITIAL_FONT_SIZE * 23 / 20) + INITIAL_FONT_SIZE + MARGIN
	k2.init(window_w, window_h, "mallorca", {window_mode = .Windowed_Resizable})
	defer k2.shutdown()

	// Dynamic font: bakes glyphs on demand, so it stays sharp at any
	// window-derived size.
	font := k2.load_dynamic_font_from_bytes(FONT_DATA)
	defer k2.destroy_font(font)
	// Separate italic face for the hover readout; karl2d can't shear an
	// upright font, so we bake a real italic instead.
	font_italic := k2.load_dynamic_font_from_bytes(FONT_ITALIC_DATA)
	defer k2.destroy_font(font_italic)

	for {
		// Drain autoreleased AppKit/GL objects every frame. Neither karl2d
		// nor a non-bundle executable sets up a per-frame pool, so without
		// this, memory grows unboundedly while idle.
		pool := NS.AutoreleasePool.alloc()->init()

		quit := !k2.update() || (ctrl_held() && k2.key_went_down(.Q))
		if !quit {
			handle_input(&app)
			if app.p2p_active {
				p2p_poll(&app.p2p) // apply remote snapshots before ticking
				p2p_roster_tick(&app, k2.get_frame_time())
				// If the peer we were viewing left, fall back to our grid.
				if app.view_tint != HOST_VIEW && viewed_sim(&app) == nil {
					app.view_tint = HOST_VIEW
				}
			}
			update_sim(&app)
			update_blink(&app)
			tick_status(&app)

			// The window shows either our own grid or a remote player's
			// (read-only, in that player's color). Layout follows whichever
			// grid is on screen, since sizes can differ.
			view := viewed_sim(&app)
			disp := view.grid if view != nil else app.grid
			layout := compute_layout(disp)
			k2.clear(BG)
			draw_border(&app)
			if view != nil {
				draw_grid(view.grid, view.marks, font, layout, remote_tint(view.tint))
			} else {
				// Jam canvas: our editable grid plus every remote player's
				// input overlaid in their color.
				draw_selection(&app, layout)
				draw_grid(app.grid, app.marks, font, layout, FG)
				draw_jam_overlay(&app, font, layout)
				draw_cursor(&app, font, layout)
			}
			draw_legend(&app, font, layout)
			draw_room_status(&app, font, layout)
			draw_status(&app, font, layout)
			draw_hover_readout(disp, font_italic, layout, app.cursor_x, app.cursor_y, view == nil)
			draw_conn(&app)
			draw_operator_overview(&app, font)
			k2.present()

			free_all(context.temp_allocator)
		}

		pool->drain()
		if quit {
			flush_notes(&app.midi, &app.sus) // silence any sustained notes before exit
			break
		}
	}
}

//-------//
// INPUT //
//-------//

REPEAT_KEYS :: [?]k2.Keyboard_Key{.Left, .Right, .Up, .Down, .Backspace}
REPEAT_DELAY :: 0.35
REPEAT_RATE :: 0.05
AUDITION_NOTE :: u8(60)

ctrl_held :: proc() -> bool {
	// Accept Cmd on macOS as well as Ctrl.
	return(
		k2.key_is_held(.Left_Control) ||
		k2.key_is_held(.Right_Control) ||
		k2.key_is_held(.Left_Super) ||
		k2.key_is_held(.Right_Super) \
	)
}

shift_held :: proc() -> bool {
	return k2.key_is_held(.Left_Shift) || k2.key_is_held(.Right_Shift)
}

// Fires on key press, then repeats while held. `slot` indexes REPEAT_KEYS.
key_repeats :: proc(app: ^App, slot: int, key: k2.Keyboard_Key) -> bool {
	if k2.key_went_down(key) {
		app.repeat[slot] = 0
		return true
	}
	if !k2.key_is_held(key) {
		app.repeat[slot] = 0
		return false
	}
	app.repeat[slot] += k2.get_frame_time()
	if app.repeat[slot] > REPEAT_DELAY {
		app.repeat[slot] -= REPEAT_RATE
		return true
	}
	return false
}

// Shifted glyphs for non-letter keys on a US layout, covering Orca's
// I/O operators: ! (CC), # (comment), % (mono), * (bang), : (note),
// ? (pitch bend); plus ; (UDP) and = (OSC) unshifted.
Glyph_Key :: struct {
	key:     k2.Keyboard_Key,
	base:    u8, // 0 = no glyph without shift
	shifted: u8, // 0 = no glyph with shift
}

GLYPH_KEYS :: [?]Glyph_Key {
	{.N0, '0', 0},
	{.N1, '1', '!'},
	{.N2, '2', 0},
	{.N3, '3', '#'},
	{.N4, '4', '$'},
	{.N5, '5', '%'},
	{.N6, '6', 0},
	{.N7, '7', 0},
	{.N8, '8', '*'},
	{.N9, '9', 0},
	{.Semicolon, ';', ':'},
	{.Equal, '=', 0},
	{.Slash, 0, '?'},
	{.NP_Multiply, '*', '*'},
}

handle_input :: proc(app: ^App) {
	// Orca's operator guide is a modal overlay: Ctrl/Cmd+G toggles it from
	// any view, Escape closes it, and no edit/play input leaks through.
	if ctrl_held() && k2.key_went_down(.G) {
		app.show_guide = !app.show_guide
		if app.show_guide && app.audition {
			midi_note_off(&app.midi, 0, AUDITION_NOTE)
			app.audition = false
		}
		return
	}
	if app.show_guide {
		if k2.key_went_down(.Escape) {
			app.show_guide = false
		}
		return
	}

	// Audition tone: hold Enter to sound middle C (MIDI note 60) on channel
	// 0, whether playing or not — a quick way to check the MIDI output and
	// synth routing. The play border lights while it sounds.
	held := k2.key_is_held(.Enter)
	if held && !app.audition {
		midi_note_on(&app.midi, 0, AUDITION_NOTE, 100)
		app.audition = true
	} else if !held && app.audition {
		midi_note_off(&app.midi, 0, AUDITION_NOTE)
		app.audition = false
	}

	// P2p: cycle the window between our own grid and each remote peer's grid.
	// '`' steps forward, Shift+'`' backward.
	if app.p2p_active && k2.key_went_down(.Backtick) {
		cycle_view(app, -1 if shift_held() else +1)
	}

	// While viewing a remote player's grid the window is read-only: only the
	// view cycle (above) and play/pause act; all edits are suppressed.
	if viewed_sim(app) != nil {
		if k2.key_went_down(.Space) {
			toggle_play(app)
		}
		return
	}

	// Ctrl/Cmd shortcuts own the whole key event: save, step, resize,
	// clipboard, select-all. Handled first so those keys never leak into
	// movement or glyph entry.
	if ctrl_held() {
		handle_shortcuts(app)
		return
	}

	shift := shift_held()

	// Cursor movement (with key repeat). Shift extends the selection;
	// an unshifted move collapses it.
	mdx, mdy := 0, 0
	if key_repeats(app, 0, .Left) {mdx -= 1}
	if key_repeats(app, 1, .Right) {mdx += 1}
	if key_repeats(app, 2, .Up) {mdy -= 1}
	if key_repeats(app, 3, .Down) {mdy += 1}
	if mdx != 0 || mdy != 0 {
		if shift {
			begin_selection(app)
		} else {
			app.sel_active = false
		}
		app.cursor_x = clamp(app.cursor_x + mdx, 0, app.grid.width - 1)
		app.cursor_y = clamp(app.cursor_y + mdy, 0, app.grid.height - 1)
	}

	// BPM adjust: '<' / '>' (Shift+Comma / Shift+Period).
	if shift {
		if k2.key_went_down(.Comma) {adjust_bpm(app, -1)}
		if k2.key_went_down(.Period) {adjust_bpm(app, +1)}
	}

	// Insert-mode toggle.
	if k2.key_went_down(.Tab) {
		app.insert_mode = !app.insert_mode
		set_status(app, fmt.aprintf("insert %s", "on" if app.insert_mode else "off"))
	}

	// Clearing. Backspace deletes the previous cell in insert mode
	// (typewriter-style); Delete and '.' always clear in place. Shifted
	// '.' is the BPM key above, not a clear.
	if key_repeats(app, 4, .Backspace) {
		if app.insert_mode {
			app.cursor_x = max(app.cursor_x - 1, 0)
		}
		clear_cell(app)
	}
	if k2.key_went_down(.Delete) || (k2.key_went_down(.Period) && !shift) {
		clear_cell(app)
	}

	// Play/pause.
	if k2.key_went_down(.Space) {
		toggle_play(app)
	}

	// Letters: unshifted lowercase (on-bang ops), shifted uppercase
	// (every-frame ops). Keyboard_Key values match ASCII uppercase.
	for key in k2.Keyboard_Key.A ..= k2.Keyboard_Key.Z {
		if k2.key_went_down(key) {
			glyph := u8(key)
			if !shift {
				glyph += 'a' - 'A'
			}
			put_glyph(app, glyph)
		}
	}

	// Digits and symbols.
	for gk in GLYPH_KEYS {
		if k2.key_went_down(gk.key) {
			glyph := gk.shifted if shift else gk.base
			if glyph != 0 {
				put_glyph(app, glyph)
			}
		}
	}
}

// Ctrl/Cmd chords. Ctrl+arrows resize the grid; the rest are single keys.
handle_shortcuts :: proc(app: ^App) {
	if k2.key_went_down(.Left) {resize_grid_by(app, -1, 0)}
	if k2.key_went_down(.Right) {resize_grid_by(app, +1, 0)}
	if k2.key_went_down(.Up) {resize_grid_by(app, 0, -1)}
	if k2.key_went_down(.Down) {resize_grid_by(app, 0, +1)}
	if k2.key_went_down(.S) {save(app)}
	if k2.key_went_down(.F) {
		// Single-step one frame (orca-c's Ctrl+F). Release the previous
		// step's notes first so a manually stepped note never hangs past
		// the next step regardless of its programmed duration.
		flush_notes(&app.midi, &app.sus)
		step_tick(app)
	}
	if k2.key_went_down(.C) {copy_selection(app)}
	if k2.key_went_down(.X) {cut_selection(app)}
	if k2.key_went_down(.V) {paste_clip(app)}
	if k2.key_went_down(.A) {select_all(app)}
	if k2.key_went_down(.Z) {undo(app)}
	if k2.key_went_down(.R) && app.p2p_active {
		system_clipboard_write(app.p2p.hash)
		set_status(app, fmt.aprintf("room id copied"))
	}
}

// Toggle playback of the shared clock (drives our grid and every remote sim).
toggle_play :: proc(app: ^App) {
	app.playing = !app.playing
	app.accum = 0
	if !app.playing {
		flush_notes(&app.midi, &app.sus) // don't leave notes hanging when stopping
	}
	if app.p2p_active {
		p2p_share_transport(&app.p2p, app.bpm, app.playing)
	}
	set_status(app, fmt.aprintf("%s", "playing" if app.playing else "paused"))
}

//--------------//
// REMOTE VIEWS //
//--------------//

// app.view_tint == HOST_VIEW means the window shows the host's own (editable)
// grid; any other value selects the remote player carrying that tint.
HOST_VIEW :: -1

// The remote peer's sim currently on screen, or nil when we're showing our
// own grid (or the viewed peer has since left).
viewed_sim :: proc(app: ^App) -> ^Peer_Sim {
	if !app.p2p_active || app.view_tint == HOST_VIEW {
		return nil
	}
	for _, sim in app.p2p.sims {
		if sim.tint == app.view_tint {
			return sim
		}
	}
	return nil
}

// Per-player glyph color, so each remote player's input is distinct from the
// host's white and from every other player.
remote_tint :: proc(tint: int) -> k2.Color {
	tints := REMOTE_TINTS // a constant array can't be indexed by a variable
	return tints[tint %% len(tints)]
}

// Step the window's view across participants: our own grid (HOST_VIEW) then
// each remote peer in join order, wrapping around. `dir` is +1 or -1.
cycle_view :: proc(app: ^App, dir: int) {
	if !app.p2p_active {
		return
	}
	// Ordered participant list: HOST_VIEW first, then remote tints ascending
	// (tints are handed out monotonically, so ascending == join order).
	tints := make([dynamic]int, context.temp_allocator)
	append(&tints, HOST_VIEW)
	for _, sim in app.p2p.sims {
		append(&tints, sim.tint)
	}
	slice.sort(tints[:])

	cur := 0
	for t, i in tints {
		if t == app.view_tint {
			cur = i
			break
		}
	}
	app.view_tint = tints[(cur + dir + len(tints)) %% len(tints)]

	if sim := viewed_sim(app); sim != nil {
		name := sim.name if sim.name != "" else "player"
		set_status(app, fmt.aprintf("viewing %s (read-only)", name))
	} else {
		set_status(app, fmt.aprintf("viewing your grid"))
	}
}

// Write a glyph at the cursor, collapsing any selection. In insert mode
// the cursor then advances east (stopping at the right edge).
put_glyph :: proc(app: ^App, glyph: u8) {
	push_undo(app)
	orca.grid_set(app.grid, app.cursor_x, app.cursor_y, glyph)
	app.sel_active = false
	app.dirty = true
	if app.insert_mode {
		app.cursor_x = min(app.cursor_x + 1, app.grid.width - 1)
	}
}

// Clear the active selection if there is one, otherwise the single cursor
// cell. (Backspace/Delete/'.' all route here.)
clear_cell :: proc(app: ^App) {
	push_undo(app)
	x0, y0, x1, y1 := selection_rect(app)
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			orca.grid_set(app.grid, x, y, orca.EMPTY_GLYPH)
		}
	}
	app.dirty = true
}

adjust_bpm :: proc(app: ^App, d: int) {
	app.bpm = clamp(app.bpm + d, BPM_MIN, BPM_MAX)
	if app.p2p_active {
		p2p_share_transport(&app.p2p, app.bpm, app.playing)
	}
	set_status(app, fmt.aprintf("%d bpm", app.bpm))
}

//-----------//
// SELECTION //
//-----------//

// Start a selection anchored at the cursor if one isn't already active.
begin_selection :: proc(app: ^App) {
	if !app.sel_active {
		app.sel_active = true
		app.sel_x = app.cursor_x
		app.sel_y = app.cursor_y
		if app.debug {
			fmt.eprintfln("select: anchor at (%d,%d)", app.sel_x, app.sel_y)
		}
	}
}

// The selected rectangle in grid coordinates. An inactive selection is the
// single cursor cell, so copy/cut always have something to act on.
selection_rect :: proc(app: ^App) -> (x0, y0, x1, y1: int) {
	if !app.sel_active {
		return app.cursor_x, app.cursor_y, app.cursor_x, app.cursor_y
	}
	return min(
		app.sel_x,
		app.cursor_x,
	), min(app.sel_y, app.cursor_y), max(app.sel_x, app.cursor_x), max(app.sel_y, app.cursor_y)
}

select_all :: proc(app: ^App) {
	app.sel_active = true
	app.sel_x, app.sel_y = 0, 0
	app.cursor_x = app.grid.width - 1
	app.cursor_y = app.grid.height - 1
}

copy_selection :: proc(app: ^App) {
	x0, y0, x1, y1 := selection_rect(app)
	w, h := x1 - x0 + 1, y1 - y0 + 1
	delete(app.clip_cells)
	app.clip_cells = make([]u8, w * h)
	app.clip_w, app.clip_h = w, h
	for y in 0 ..< h {
		for x in 0 ..< w {
			app.clip_cells[y * w + x] = orca.grid_get(app.grid, x0 + x, y0 + y)
		}
	}
	// Mirror the block to the system pasteboard (rows joined by '\n') so it can
	// be pasted into other apps, and so our own paste — which prefers the
	// system clipboard — round-trips an in-app copy faithfully.
	system_clipboard_write(clip_to_text(app, context.temp_allocator))
	if app.debug {
		fmt.eprintfln(
			"copy: sel_active=%v rect=(%d,%d)-(%d,%d) -> %dx%d %q",
			app.sel_active,
			x0,
			y0,
			x1,
			y1,
			w,
			h,
			string(app.clip_cells),
		)
	}
	set_status(app, fmt.aprintf("copied %dx%d", w, h))
}

cut_selection :: proc(app: ^App) {
	copy_selection(app)
	push_undo(app)
	x0, y0, x1, y1 := selection_rect(app)
	for y in y0 ..= y1 {
		for x in x0 ..= x1 {
			orca.grid_set(app.grid, x, y, orca.EMPTY_GLYPH)
		}
	}
	app.sel_active = false
	app.dirty = true
	set_status(app, fmt.aprintf("cut %dx%d", app.clip_w, app.clip_h))
}

// Serialize the internal clipboard block to text, rows joined by '\n'.
clip_to_text :: proc(app: ^App, allocator := context.allocator) -> string {
	b: strings.Builder
	strings.builder_init(&b, allocator)
	for y in 0 ..< app.clip_h {
		if y > 0 {
			strings.write_byte(&b, '\n')
		}
		strings.write_bytes(&b, app.clip_cells[y * app.clip_w:y * app.clip_w + app.clip_w])
	}
	return strings.to_string(b)
}

// Paste at the cursor. Prefers the system pasteboard so a pattern copied from
// anywhere drops into the grid; falls back to the internal block clipboard
// when the pasteboard has no usable text.
paste_clip :: proc(app: ^App) {
	if text, ok := system_clipboard_read(context.temp_allocator); ok {
		if app.debug {
			fmt.eprintfln(
				"paste: system clipboard %q at cursor=(%d,%d)",
				text,
				app.cursor_x,
				app.cursor_y,
			)
		}
		paste_text(app, text)
		return
	}
	if app.debug {
		fmt.eprintfln(
			"paste: internal clip=%dx%d at cursor=(%d,%d) %q",
			app.clip_w,
			app.clip_h,
			app.cursor_x,
			app.cursor_y,
			string(app.clip_cells),
		)
	}
	if app.clip_w == 0 {
		set_status(app, fmt.aprintf("nothing to paste"))
		return
	}
	push_undo(app)
	for y in 0 ..< app.clip_h {
		for x in 0 ..< app.clip_w {
			orca.grid_set(
				app.grid,
				app.cursor_x + x,
				app.cursor_y + y,
				app.clip_cells[y * app.clip_w + x],
			)
		}
	}
	app.sel_active = false // drop the highlight so the paste is visible
	app.dirty = true
	set_status(app, fmt.aprintf("pasted %dx%d", app.clip_w, app.clip_h))
}

// Paste free-form text at the cursor: '\n' starts a new row (back at the
// cursor column), '\r' is ignored, non-printable bytes become empty cells.
// Cells past the grid edge are dropped (grid_set clips).
paste_text :: proc(app: ^App, text: string) {
	push_undo(app)
	x, y := app.cursor_x, app.cursor_y
	lines := 1
	for c in transmute([]u8)text {
		switch c {
		case '\n':
			y += 1
			x = app.cursor_x
			lines += 1
		case '\r':
		// ignored
		case:
			glyph := c if c >= '!' && c <= '~' else orca.EMPTY_GLYPH
			orca.grid_set(app.grid, x, y, glyph)
			x += 1
		}
	}
	app.sel_active = false
	app.dirty = true
	set_status(app, fmt.aprintf("pasted %d line%s", lines, "" if lines == 1 else "s"))
}

// Reallocate the grid (and mark buffer), preserving the overlapping
// top-left content and clamping the cursor into the new bounds.
resize_grid_by :: proc(app: ^App, dw, dh: int) {
	nw := clamp(app.grid.width + dw, 1, orca.MAX_DIM)
	nh := clamp(app.grid.height + dh, 1, orca.MAX_DIM)
	if nw == app.grid.width && nh == app.grid.height {
		return
	}
	push_undo(app)
	ng := orca.resize_grid(app.grid, nw, nh)
	orca.destroy_grid(&app.grid)
	app.grid = ng
	delete(app.marks)
	app.marks = orca.make_marks(app.grid)
	app.cursor_x = clamp(app.cursor_x, 0, nw - 1)
	app.cursor_y = clamp(app.cursor_y, 0, nh - 1)
	app.sel_active = false
	app.dirty = true
	set_status(app, fmt.aprintf("%dx%d", nw, nh))
}

//------//
// UNDO //
//------//

// Snapshot the grid and cursor before a mutating edit. Coalescing is left to
// callers; every call here records one undo step. Oldest steps past UNDO_MAX
// are dropped.
push_undo :: proc(app: ^App) {
	snap := Undo_Snapshot {
		cells    = make([]u8, len(app.grid.cells)),
		width    = app.grid.width,
		height   = app.grid.height,
		cursor_x = app.cursor_x,
		cursor_y = app.cursor_y,
	}
	copy(snap.cells, app.grid.cells)
	append(&app.undo, snap)
	if len(app.undo) > UNDO_MAX {
		delete(app.undo[0].cells)
		ordered_remove(&app.undo, 0)
	}
}

// Restore the most recent snapshot, replacing the current grid (and rebuilding
// marks if the dimensions changed).
undo :: proc(app: ^App) {
	if len(app.undo) == 0 {
		set_status(app, fmt.aprintf("nothing to undo"))
		return
	}
	snap := pop(&app.undo)
	resized := snap.width != app.grid.width || snap.height != app.grid.height
	orca.destroy_grid(&app.grid)
	app.grid = orca.Grid {
		cells  = snap.cells, // transfer ownership of the snapshot buffer
		width  = snap.width,
		height = snap.height,
	}
	if resized {
		delete(app.marks)
		app.marks = orca.make_marks(app.grid)
	}
	app.cursor_x = clamp(snap.cursor_x, 0, app.grid.width - 1)
	app.cursor_y = clamp(snap.cursor_y, 0, app.grid.height - 1)
	app.sel_active = false
	app.dirty = true
	set_status(app, fmt.aprintf("undo (%d left)", len(app.undo)))
}

clear_undo :: proc(app: ^App) {
	for snap in app.undo {
		delete(snap.cells)
	}
	delete(app.undo)
	app.undo = nil
}

//------------//
// SIMULATION //
//------------//

// Cap on ticks consumed per rendered frame, so a stall (window drag,
// sleep) doesn't fire a burst of catch-up ticks. (Mallorca policy;
// orca-c has no such cap.)
MAX_TICKS_PER_FRAME :: 8

step_tick :: proc(app: ^App) {
	orca.run_tick(app.grid, app.marks, app.tick, 0, &app.events)
	advance_notes(&app.midi, &app.sus) // expire notes triggered on earlier ticks first
	dispatch_events(&app.midi, &app.sus, app.events[:]) // then emit this tick's events
	app.tick += 1
	app.dirty = false
}

// Count down every sustained note by one frame; send note-off for any that
// reach the end of their duration.
// The note scheduler takes (midi, sus) rather than the whole App so both the
// GUI host and the headless network host (net.odin) share one implementation.
advance_notes :: proc(midi: ^Midi, sus: ^[dynamic]Sus_Note) {
	i := 0
	for i < len(sus) {
		sus[i].frames -= 1
		if sus[i].frames <= 0 {
			midi_note_off(midi, sus[i].channel, sus[i].note)
			unordered_remove(sus, i)
		} else {
			i += 1
		}
	}
}

// Turn a tick's VM events into MIDI. OSC ('=') and UDP (';') are network
// transports and remain deferred; the VM still produces them.
dispatch_events :: proc(midi: ^Midi, sus: ^[dynamic]Sus_Note, events: []orca.Event) {
	for ev in events {
		switch e in ev {
		case orca.Midi_Note_Event:
			note := u8(clamp(int(e.octave) * 12 + int(e.note), 0, 127))
			if e.mono {
				stop_channel(midi, sus, e.channel) // '%' steals its channel
			}
			midi_note_on(midi, e.channel, note, e.velocity)
			append(
				sus,
				Sus_Note{channel = e.channel, note = note, frames = max(int(e.duration), 1)},
			)
		case orca.Midi_CC_Event:
			midi_cc(midi, e.channel, e.control, e.value)
		case orca.Midi_PB_Event:
			midi_pitch_bend(midi, e.channel, e.lsb, e.msb)
		case orca.Osc_Ints_Event: // deferred
		case orca.Udp_String_Event: // deferred
		}
	}
}

// Send note-off for and drop every sustained note on `channel` (monophony).
stop_channel :: proc(midi: ^Midi, sus: ^[dynamic]Sus_Note, channel: u8) {
	i := 0
	for i < len(sus) {
		if sus[i].channel == channel {
			midi_note_off(midi, sus[i].channel, sus[i].note)
			unordered_remove(sus, i)
		} else {
			i += 1
		}
	}
}

// Silence and forget all sustained notes (pause, quit, or device change).
flush_notes :: proc(midi: ^Midi, sus: ^[dynamic]Sus_Note) {
	for n in sus {
		midi_note_off(midi, n.channel, n.note)
	}
	clear(sus)
}

update_sim :: proc(app: ^App) {
	if app.playing {
		app.accum += k2.get_frame_time()
		frame := frame_seconds(app.bpm)
		ticks := 0
		for app.accum >= frame && ticks < MAX_TICKS_PER_FRAME {
			app.accum -= frame
			step_tick(app) // our own grid (runs advance_notes once for all)
			if app.p2p_active {
				p2p_send_own(&app.p2p, app.grid, app.tick) // broadcast our grid
			}
			ticks += 1
		}
		if app.accum >= frame {
			// Drop whole overdue ticks but keep the fractional phase, so
			// a stall doesn't shift subsequent tick deadlines.
			app.accum = math.mod(app.accum, frame)
		}
	} else if app.dirty {
		// Fresh highlighting while paused: compute marks from a scratch
		// copy of the grid without advancing the simulation.
		orca.preview_marks(app.grid, app.marks, app.tick, 0)
		app.dirty = false
		if app.p2p_active {
			p2p_send_own(&app.p2p, app.grid, app.tick) // reflect paused edits
		}
	}
}

save :: proc(app: ^App) {
	if app.file_name == "" {
		app.file_name = DEFAULT_FILE_NAME
	}
	data := orca.serialize_field(app.grid, context.temp_allocator)
	err := os.write_entire_file(app.file_name, data)
	if err != nil {
		set_status(app, fmt.aprintf("save failed: %v", err))
	} else {
		set_status(app, fmt.aprintf("saved %s", app.file_name))
	}
}

STATUS_MSG_SECONDS :: 2.0

// Takes ownership of `msg` (heap-allocated); freed when it expires.
set_status :: proc(app: ^App, msg: string) {
	if app.status_msg != "" {
		delete(app.status_msg)
	}
	app.status_msg = msg
	app.status_timer = STATUS_MSG_SECONDS
}

// Advance the cursor blink. Any cursor movement resets the phase to fully
// visible, so the cursor never blinks away the instant you move or type.
update_blink :: proc(app: ^App) {
	if app.cursor_x != app.blink_x || app.cursor_y != app.blink_y {
		app.blink = 0
		app.blink_x = app.cursor_x
		app.blink_y = app.cursor_y
	}
	app.blink += k2.get_frame_time()
}

// True during the "on" half of the blink cycle.
cursor_visible :: proc(app: ^App) -> bool {
	return int(app.blink / BLINK_INTERVAL) % 2 == 0
}

tick_status :: proc(app: ^App) {
	if app.status_timer <= 0 {
		return
	}
	app.status_timer -= k2.get_frame_time()
	if app.status_timer <= 0 && app.status_msg != "" {
		delete(app.status_msg)
		app.status_msg = ""
	}
}

Layout :: struct {
	cell_w:    f32,
	cell_h:    f32,
	font_size: f32,
}

// The grid always spans the full window width; cell and font size follow.
compute_layout :: proc(grid: orca.Grid) -> Layout {
	cell_w := (f32(k2.get_screen_width()) - MARGIN * 2) / f32(grid.width)
	font_size := cell_w / ADVANCE_EM
	return Layout{cell_w = cell_w, cell_h = font_size * LINE_EM, font_size = font_size}
}

// Solid frame just inside the window edges signalling play state:
// green while playing, nothing while paused.
draw_border :: proc(app: ^App) {
	// Green frame while playing, or while the Enter audition tone sounds.
	if !app.playing && !app.audition {
		return
	}
	rect := k2.Rect {
		BORDER_INSET,
		BORDER_INSET,
		f32(k2.get_screen_width()) - BORDER_INSET * 2,
		f32(k2.get_screen_height()) - BORDER_INSET * 2,
	}
	k2.draw_rect_outline(rect, BORDER_THICKNESS, PLAY_BORDER)
}

// A small square in the top-right showing p2p room connection status.
// Drawn only when a room is open.
draw_conn :: proc(app: ^App) {
	if !app.p2p_active {
		return
	}
	color := CONN_BAD
	#partial switch app.p2p.status {
	case .Connected:
		color = CONN_OK
	case .Alone:
		color = CONN_WAIT
	}
	size: f32 = 14
	x := f32(k2.get_screen_width()) - MARGIN - size
	k2.draw_rect(k2.Rect{x, f32(MARGIN), size, size}, color)
}

//-----------------//
// M10 HOVER READOUT //
//-----------------//

// Full operator names for the hover readout (M10). Mirrors the op_* procs in
// core/sim.odin; lowercase operators are qualified because they only run next
// to a bang. Returns "" for non-operator cells (`.`, digits, bare data).
operator_name :: proc(glyph: u8) -> string {
	switch glyph {
	case 'A':
		return "add"
	case 'a':
		return "add (bang)"
	case 'B':
		return "subtract"
	case 'b':
		return "subtract (bang)"
	case 'C':
		return "clock"
	case 'c':
		return "clock (bang)"
	case 'D':
		return "delay"
	case 'd':
		return "delay (bang)"
	case 'E':
		return "move east"
	case 'e':
		return "move east (bang)"
	case 'F':
		return "if"
	case 'f':
		return "if (bang)"
	case 'G':
		return "generator"
	case 'g':
		return "generator (bang)"
	case 'H':
		return "halt"
	case 'h':
		return "halt (bang)"
	case 'I':
		return "increment"
	case 'i':
		return "increment (bang)"
	case 'J':
		return "jump"
	case 'j':
		return "jump (bang)"
	case 'K':
		return "konkat"
	case 'k':
		return "konkat (bang)"
	case 'L':
		return "lesser"
	case 'l':
		return "lesser (bang)"
	case 'M':
		return "multiply"
	case 'm':
		return "multiply (bang)"
	case 'N':
		return "move north"
	case 'n':
		return "move north (bang)"
	case 'O':
		return "offset (read)"
	case 'o':
		return "offset (read, bang)"
	case 'P':
		return "push"
	case 'p':
		return "push (bang)"
	case 'Q':
		return "query"
	case 'q':
		return "query (bang)"
	case 'R':
		return "random"
	case 'r':
		return "random (bang)"
	case 'S':
		return "move south"
	case 's':
		return "move south (bang)"
	case 'T':
		return "track"
	case 't':
		return "track (bang)"
	case 'U':
		return "euclid"
	case 'u':
		return "euclid (bang)"
	case 'V':
		return "variable"
	case 'v':
		return "variable (bang)"
	case 'W':
		return "move west"
	case 'w':
		return "move west (bang)"
	case 'X':
		return "teleport"
	case 'x':
		return "teleport (bang)"
	case 'Y':
		return "yump"
	case 'y':
		return "yump (bang)"
	case 'Z':
		return "lerp"
	case 'z':
		return "lerp (bang)"
	case '*':
		return "bang"
	case '#':
		return "comment"
	case ':':
		return "midi (note)"
	case '%':
		return "midi (mono)"
	case '!':
		return "midi cc"
	case '?':
		return "pitch bend"
	case ';':
		return "udp"
	case '=':
		return "osc"
	}
	return ""
}

//--------------------------//
// OPERATOR OVERVIEW GUIDE  //
//--------------------------//

Operator_Overview_Entry :: struct {
	glyph: string,
	text:  string,
}

// Canonical summaries from the original Orca guide, adjusted only where
// Mallorca uses the orca-c operator name (jump, euclid, yump).
OPERATOR_OVERVIEW :: [?]Operator_Overview_Entry {
	{"A", "add(a b): Sum inputs."},
	{"B", "subtract(a b): Difference of inputs."},
	{"C", "clock(rate mod): Frame modulo."},
	{"D", "delay(rate mod): Bang on modulo."},
	{"E", "east: Move east, or bang."},
	{"F", "if(a b): Bang when inputs match."},
	{"G", "generator(x y len): Write at offset."},
	{"H", "halt: Stop southward operand."},
	{"I", "increment(step mod): Increment below."},
	{"J", "jump(val): Output north operand."},
	{"K", "konkat(len): Read variables."},
	{"L", "less(a b): Output smallest input."},
	{"M", "multiply(a b): Product of inputs."},
	{"N", "north: Move north, or bang."},
	{"O", "read(x y read): Read at offset."},
	{"P", "push(len key val): Write east."},
	{"Q", "query(x y len): Read at offset."},
	{"R", "random(min max): Random value."},
	{"S", "south: Move south, or bang."},
	{"T", "track(key len val): Read east."},
	{"U", "euclid(step max): Euclidean bang."},
	{"V", "variable(write read): Read/write var."},
	{"W", "west: Move west, or bang."},
	{"X", "write(x y val): Write at offset."},
	{"Y", "yump(val): Output west operand."},
	{"Z", "lerp(rate target): Move toward input."},
	{"*", "bang: Trigger neighboring operators."},
	{"#", "comment: Halts a line."},
	{":", "midi(ch oct note vel len): Send note."},
	{"%", "mono(ch oct note vel len): Send mono."},
	{"!", "cc(channel knob value): Send MIDI CC."},
	{"?", "pitch bend(channel value): Send bend."},
	{";", "udp: Send UDP message."},
	{"=", "osc(path): Send OSC message."},
}

// Full-window guide modeled on Orca's Cmd/Ctrl+G overview. Try one through
// four columns and choose whichever yields the largest type that fits both
// available dimensions.
draw_operator_overview :: proc(app: ^App, font: k2.Font) {
	if !app.show_guide {
		return
	}

	screen_w := f32(k2.get_screen_width())
	screen_h := f32(k2.get_screen_height())
	k2.draw_rect({0, 0, screen_w, screen_h}, k2.Color{0x17, 0x17, 0x17, 0xf8})

	padding := f32(MARGIN)
	text_x_em := f32(1.8)
	line_h_em := f32(1.3)
	header_size_em := f32(1.25)
	header_y_em := f32(1.75)

	// Measure at a large reference size for stable per-em widths.
	measure_size := f32(100)
	max_line_em: f32
	for entry in OPERATOR_OVERVIEW {
		text_em := k2.measure_text(entry.text, measure_size, font).x / measure_size
		max_line_em = max(max_line_em, text_x_em + text_em)
	}

	font_size: f32
	columns := 1
	for candidate_columns in 1 ..= 4 {
		candidate_rows := (len(OPERATOR_OVERVIEW) + candidate_columns - 1) / candidate_columns
		candidate_column_w := (screen_w - padding * 2) / f32(candidate_columns)
		width_size := max(candidate_column_w - padding, f32(1)) / max_line_em
		height_em := header_size_em * header_y_em + f32(candidate_rows - 1) * line_h_em + 1
		height_size := max(screen_h - padding * 2, f32(1)) / height_em
		candidate_size := min(width_size, height_size)
		if candidate_size > font_size {
			font_size = candidate_size
			columns = candidate_columns
		}
	}
	font_size = max(font_size, f32(8))

	rows := (len(OPERATOR_OVERVIEW) + columns - 1) / columns
	header_size := font_size * header_size_em
	line_gap := font_size * (line_h_em - 1)
	line_h := font_size + line_gap
	column_w := (screen_w - padding * 2) / f32(columns)

	k2.draw_text("OPERATORS", {padding, padding}, header_size, SECONDARY, font)
	hint := "Ctrl/Cmd+G or Esc to close"
	hint_w := k2.measure_text(hint, font_size, font).x
	k2.draw_text(hint, {screen_w - padding - hint_w, padding}, font_size, STATUS, font)

	y0 := padding + header_size * 1.75
	for entry, i in OPERATOR_OVERVIEW {
		column := i / rows
		row := i % rows
		x := padding + f32(column) * column_w
		y := y0 + f32(row) * line_h
		k2.draw_text(entry.glyph, {x, y}, font_size, SECONDARY, font)
		k2.draw_text(entry.text, {x + font_size * text_x_em, y}, font_size, FG, font)
	}
}

// Map the mouse pointer to a grid cell (inverse of the cell-rect layout the
// renderer uses), or (-1, -1) when the pointer is outside the grid.
hover_cell :: proc(grid: orca.Grid, layout: Layout) -> (cx, cy: int) {
	m := k2.get_mouse_position()
	fx := (m.x - MARGIN) / layout.cell_w
	fy := (m.y - MARGIN) / layout.cell_h
	if fx < 0 || fy < 0 {
		return -1, -1
	}
	cx, cy = int(fx), int(fy)
	if cx >= grid.width || cy >= grid.height {
		return -1, -1
	}
	return cx, cy
}

// M10: show the operator beneath the mouse, falling back to the keyboard edit
// cursor when the pointer is not on an operator. The fallback is disabled while
// viewing another player's grid because the local edit cursor is not displayed
// there. Drawn on its own line just above the status bar (right-aligned) so a
// long status line can't cover it. `font` is the bundled italic face (see
// FONT_ITALIC_DATA / main).
//
// Note: the readout only appears while the window is focused — macOS delivers
// mouse-moved events to the key window only, so an unfocused window reports a
// stale pointer.
draw_hover_readout :: proc(
	grid: orca.Grid,
	font: k2.Font,
	layout: Layout,
	cursor_x, cursor_y: int,
	cursor_fallback: bool,
) {
	cx, cy := hover_cell(grid, layout)
	name := ""
	if cx >= 0 {
		name = operator_name(orca.grid_get(grid, cx, cy))
	}
	if name == "" &&
	   cursor_fallback &&
	   cursor_x >= 0 &&
	   cursor_x < grid.width &&
	   cursor_y >= 0 &&
	   cursor_y < grid.height {
		name = operator_name(orca.grid_get(grid, cursor_x, cursor_y))
	}
	if name == "" {
		return
	}
	size := layout.font_size * STATUS_SCALE
	w := k2.measure_text(name, size, font).x
	x := f32(k2.get_screen_width()) - MARGIN - w
	// One line above the status bar (which sits at height - size - MARGIN).
	y := f32(k2.get_screen_height()) - size * 2 - MARGIN
	k2.draw_text(name, {x, y}, size, SECONDARY, font)
}

// Muted fill behind the selected rectangle, drawn under the glyphs.
draw_selection :: proc(app: ^App, layout: Layout) {
	if !app.sel_active {
		return
	}
	x0, y0, x1, y1 := selection_rect(app)
	rect := k2.Rect {
		MARGIN + f32(x0) * layout.cell_w,
		MARGIN + f32(y0) * layout.cell_h,
		f32(x1 - x0 + 1) * layout.cell_w,
		f32(y1 - y0 + 1) * layout.cell_h,
	}
	k2.draw_rect(rect, SELECT)
}

// `base` is the default glyph color (the host's white for our grid; a remote
// player's tint for their grid). Empty-cell ruler/dim and per-cell marks
// override it exactly as before.
draw_grid :: proc(
	grid: orca.Grid,
	marks: []orca.Mark,
	font: k2.Font,
	layout: Layout,
	base: k2.Color,
) {
	buf: [1]u8
	for y in 0 ..< grid.height {
		for x in 0 ..< grid.width {
			glyph := orca.grid_get(grid, x, y)
			mark := marks[y * grid.width + x]
			pos := k2.Vec2{MARGIN + f32(x) * layout.cell_w, MARGIN + f32(y) * layout.cell_h}
			color := base
			if glyph == orca.EMPTY_GLYPH {
				// Ruler overlay: '+' every 8x8 intersection, dim '.' elsewhere.
				if x % RULER_SPACING == 0 && y % RULER_SPACING == 0 {
					glyph = '+'
					color = RULER
				} else {
					color = DIM
				}
			}
			// Marks style empty cells too, matching orca-c's tui; haste
			// wins over output (orca-c applies it last).
			switch {
			case .Haste_Input in mark:
				color = HASTE
			case .Output in mark:
				// Freshly written cells draw inverted, like Orca.
				rect := k2.Rect{pos.x, pos.y, layout.cell_w, layout.cell_h}
				k2.draw_rect(rect, PROJECTED if .Projected in mark else OUTPUT_BG)
				color = OUTPUT_FG
			case .Input in mark:
				color = INPUT
			case .Lock in mark:
				color = LOCKED
			}
			buf[0] = glyph
			k2.draw_text(string(buf[:]), pos, layout.font_size, color, font)
			if .Projected in mark {
				// Draw only exposed edges so adjacent projected cells read as
				// one destination region rather than a row of boxed cells.
				thickness := PROJECTED_BORDER_THICKNESS
				if y == 0 || .Projected not_in marks[(y - 1) * grid.width + x] {
					k2.draw_rect({pos.x, pos.y, layout.cell_w, thickness}, PROJECTED)
				}
				if y == grid.height - 1 || .Projected not_in marks[(y + 1) * grid.width + x] {
					k2.draw_rect(
						{pos.x, pos.y + layout.cell_h - thickness, layout.cell_w, thickness},
						PROJECTED,
					)
				}
				if x == 0 || .Projected not_in marks[y * grid.width + x - 1] {
					k2.draw_rect({pos.x, pos.y, thickness, layout.cell_h}, PROJECTED)
				}
				if x == grid.width - 1 || .Projected not_in marks[y * grid.width + x + 1] {
					k2.draw_rect(
						{pos.x + layout.cell_w - thickness, pos.y, thickness, layout.cell_h},
						PROJECTED,
					)
				}
			}
		}
	}
}

// Inverted cell at the cursor; empty cells show '@' (like Orca) so the
// cursor is always visible.
draw_cursor :: proc(app: ^App, font: k2.Font, layout: Layout) {
	// Off half of the blink: skip the cursor so the underlying cell shows.
	if !cursor_visible(app) {
		return
	}
	glyph := orca.grid_get(app.grid, app.cursor_x, app.cursor_y)
	if glyph == orca.EMPTY_GLYPH {
		glyph = '@'
	}
	pos := k2.Vec2 {
		MARGIN + f32(app.cursor_x) * layout.cell_w,
		MARGIN + f32(app.cursor_y) * layout.cell_h,
	}
	rect := k2.Rect{pos.x, pos.y, layout.cell_w, layout.cell_h}
	k2.draw_rect(rect, CURSOR_BG)
	buf := [1]u8{glyph}
	k2.draw_text(string(buf[:]), pos, layout.font_size, CURSOR_FG, font)
}

draw_status :: proc(app: ^App, font: k2.Font, layout: Layout) {
	text: string
	if app.status_msg != "" {
		text = app.status_msg
	} else if sim := viewed_sim(app); sim != nil {
		who := sim.name if sim.name != "" else "player"
		text = fmt.tprintf(
			"viewing %s   %dx%d   %dt   read-only   ` to cycle",
			who,
			sim.grid.width,
			sim.grid.height,
			sim.tick,
		)
	} else {
		name := app.file_name if app.file_name != "" else "(unsaved)"
		mode := "  play" if app.playing else "  stop"
		if app.insert_mode {
			mode = fmt.tprintf("%s  ins", mode)
		}
		if app.midi.ok {
			mode = fmt.tprintf("%s  midi%s", mode, "+dev" if app.midi.has_dest else "")
		}
		// P2p mode: show how many remote peers are connected and how to view
		// their grids. A live 0 here means nobody else has joined this room.
		if app.p2p_active {
			n := len(app.p2p.sims)
			hint := "  ` to view" if n > 0 else ""
			mode = fmt.tprintf("%s  %d remote%s", mode, n, hint)
		}
		text = fmt.tprintf(
			"%s   %dx%d   %d,%d   %df   %dbpm%s",
			name,
			app.grid.width,
			app.grid.height,
			app.cursor_x,
			app.cursor_y,
			app.tick,
			app.bpm,
			mode,
		)
	}
	// The status line is heads-up/debug info, so draw it smaller than the
	// grid glyphs (60%) to keep it fitting within the window width.
	size := layout.font_size * STATUS_SCALE
	y := f32(k2.get_screen_height()) - size - MARGIN
	k2.draw_text(text, {MARGIN, y}, size, STATUS, font)
}

// Jam canvas (M8): overlay every remote player's non-empty glyphs onto the
// host's own grid in that player's tint, so the host sees everyone's input at
// once. Only cells the host left empty are painted, so the host's own white
// glyphs stay legible; remote input reads as color. Sims are drawn in tint
// (join) order so overlapping remote cells don't flicker with map iteration.
draw_jam_overlay :: proc(app: ^App, font: k2.Font, layout: Layout) {
	if !app.p2p_active || len(app.p2p.sims) == 0 {
		return
	}
	order := make([dynamic]^Peer_Sim, context.temp_allocator)
	for _, sim in app.p2p.sims {
		append(&order, sim)
	}
	slice.sort_by(order[:], proc(a, b: ^Peer_Sim) -> bool {return a.tint < b.tint})

	buf: [1]u8
	for sim in order {
		color := remote_tint(sim.tint)
		w := min(sim.grid.width, app.grid.width)
		h := min(sim.grid.height, app.grid.height)
		for y in 0 ..< h {
			for x in 0 ..< w {
				glyph := orca.grid_get(sim.grid, x, y)
				if glyph == orca.EMPTY_GLYPH {
					continue
				}
				// Don't paint over the host's own glyphs — keep those white.
				if orca.grid_get(app.grid, x, y) != orca.EMPTY_GLYPH {
					continue
				}
				pos := k2.Vec2{MARGIN + f32(x) * layout.cell_w, MARGIN + f32(y) * layout.cell_h}
				buf[0] = glyph
				k2.draw_text(string(buf[:]), pos, layout.font_size, color, font)
			}
		}
	}
}

// Room status: room name, peer count, truncated hash, and the copy-id hint,
// on its own HUD line above the legend/status lines. Shown only while a p2p
// room is open.
draw_room_status :: proc(app: ^App, font: k2.Font, layout: Layout) {
	if !app.p2p_active {
		return
	}
	size := layout.font_size * STATUS_SCALE
	y := f32(k2.get_screen_height()) - size * 3 - MARGIN - size * 0.8
	x := f32(MARGIN)

	room_name := app.p2p.room_name
	k2.draw_text(room_name, {x, y}, size, SECONDARY, font)
	x += f32(len(room_name)) * size * ADVANCE_EM + size * 1.1

	n := len(app.p2p.sims)
	peers_text := fmt.tprintf("%d peer%s", n, "" if n == 1 else "s")
	k2.draw_text(peers_text, {x, y}, size, STATUS, font)
	x += f32(len(peers_text)) * size * ADVANCE_EM + size * 1.1

	hash_text := p2p_hash_display(app.p2p.hash)
	k2.draw_text(hash_text, {x, y}, size, STATUS, font)
	x += f32(len(hash_text)) * size * ADVANCE_EM + size * 1.1

	k2.draw_text("^R copy id", {x, y}, size, STATUS, font)
}

// Truncate the bare room hash for HUD display (first10…last6). `app.p2p.hash`
// is already glyph-free; this only shortens.
@(private = "file")
p2p_hash_display :: proc(hash: string) -> string {
	if len(hash) <= 16 {
		return hash
	}
	return fmt.tprintf("%s…%s", hash[:10], hash[len(hash) - 6:])
}

// Legend (M8): a compact row of colored name chips just above the status line,
// mapping each remote player's tint to their name. Drawn only in host mode and
// only when at least one remote player is connected (otherwise the status
// line's "N remote" already says everything).
draw_legend :: proc(app: ^App, font: k2.Font, layout: Layout) {
	if !app.p2p_active || len(app.p2p.sims) == 0 {
		return
	}
	order := make([dynamic]^Peer_Sim, context.temp_allocator)
	for _, sim in app.p2p.sims {
		append(&order, sim)
	}
	slice.sort_by(order[:], proc(a, b: ^Peer_Sim) -> bool {return a.tint < b.tint})

	size := layout.font_size * STATUS_SCALE
	// One line above the status line (status sits at height - size - MARGIN).
	y := f32(k2.get_screen_height()) - size * 2 - MARGIN - size * 0.4
	x := f32(MARGIN)
	dot := size * 0.6
	for sim in order {
		name := sim.name if sim.name != "" else "player"
		// Filled swatch in the player's tint, then their name in the same color.
		k2.draw_rect(k2.Rect{x, y + (size - dot) * 0.5, dot, dot}, remote_tint(sim.tint))
		x += dot + size * 0.35
		k2.draw_text(name, {x, y}, size, remote_tint(sim.tint), font)
		x += f32(len(name)) * size * ADVANCE_EM + size * 1.1
	}
}
