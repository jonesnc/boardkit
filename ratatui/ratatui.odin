package ratatui

// Odin side of boardkit. The Rust shim (../shim) only wraps ratatui: terminal, keys, layout and
// one call per widget. Specs, state, bindings, validation, streaming and hot reload are here.

import "core:time"

foreign import shim "../shim/target/release/libratatui_shim.a"

Term :: distinct rawptr

Key :: enum i32 {
	None      = -1,
	Esc       = -2,
	Enter     = -3,
	Up        = -4,
	Down      = -5,
	Left      = -6,
	Right     = -7,
	Backspace = -8,
	Tab       = -9,
	PageUp    = -10,
	PageDown  = -11,
	Home      = -12,
	End       = -13,
	Other     = -100,
}

// ---- wrapper types (match shim/src/lib.rs; Odin string and []T match Str and Slice) ----

Rect :: struct {
	x, y, w, h: u16,
}

// Colors are names or #rrggbb; "" = unset. mods: BOLD | ITALIC | UNDERLINE | REVERSED | DIM.
Style :: struct {
	fg, bg: string,
	mods:   u32,
}

// kind: 0 fill, 1 length, 2 percent, 3 min, 4 max.
Cons :: struct {
	kind: i32,
	n:    u16,
}

Item :: struct {
	text:  string,
	style: Style,
}

Row :: struct {
	cells: []string,
	style: Style,
}

Series :: struct {
	name:  string,
	style: Style,
	pts:   [][2]f64,
}

Bar :: struct {
	label: string,
	value: u64,
}

// kind: 0 line (a..d = x1 y1 x2 y2), 1 rect (x y w h), 2 circle (x y r), 3 points, 4 map (a=1 high), 5 text (x y).
Shape :: struct {
	kind:       i32,
	a, b, c, d: f64,
	style:      Style,
	text:       string,
	pts:        [][2]f64,
}

Frame_Proc :: #type proc "c" (frame: rawptr, ud: rawptr)

@(default_calling_convention = "c", link_prefix = "rt_")
foreign shim {
	init        :: proc() -> Term ---
	restore     :: proc(t: Term) ---
	poll_key    :: proc(timeout_ms: u32) -> i32 ---
	take_resized :: proc() -> i32 ---
	test_init   :: proc(w, h: u16) -> Term ---
}

@(default_calling_convention = "c", private)
foreign shim {
	rt_test_screen :: proc(t: Term, buf: [^]u8, cap: int) -> int ---
	rt_test_fg     :: proc(t: Term, x, y: u16, buf: [^]u8, cap: int) -> int ---
	rt_color_ok    :: proc(s: ^string) -> i32 ---
	rt_frame       :: proc(t: Term, cb: Frame_Proc, ud: rawptr) -> i32 ---
	rt_frame_area  :: proc(f: rawptr, out: ^Rect) ---
	rt_layout      :: proc(area: ^Rect, vertical: i32, c: [^]Cons, n: int, out: [^]Rect) ---
	rt_clear       :: proc(f: rawptr, area: ^Rect) ---
	rt_block       :: proc(f: rawptr, area: ^Rect, title: ^string, st: ^Style, inner: ^Rect) ---
	rt_paragraph   :: proc(f: rawptr, area: ^Rect, text: ^string, st: ^Style, scroll: u16) ---
	rt_list        :: proc(f: rawptr, area: ^Rect, items: [^]Item, n: int, st: ^Style, selected: i64) ---
	rt_gauge       :: proc(f: rawptr, area: ^Rect, ratio: f64, label: ^string, st: ^Style) ---
	rt_linegauge   :: proc(f: rawptr, area: ^Rect, ratio: f64, label: ^string, st: ^Style) ---
	rt_chart       :: proc(f: rawptr, area: ^Rect, series: [^]Series, n: int, x_title, y_title: ^string, bounds: ^[4]f64) ---
	rt_calendar    :: proc(f: rawptr, area: ^Rect, year: i32, month: u8, highlight: [^]u8, n: int, st: ^Style) ---
	rt_canvas      :: proc(f: rawptr, area: ^Rect, xb, yb: ^[2]f64, shapes: [^]Shape, n: int) ---
	rt_logo        :: proc(f: rawptr, area: ^Rect, small: i32) ---
	rt_mascot      :: proc(f: rawptr, area: ^Rect) ---
	rt_sparkline   :: proc(f: rawptr, area: ^Rect, data: [^]u64, n: int, st: ^Style) ---
	rt_tabs        :: proc(f: rawptr, area: ^Rect, titles: [^]string, n: int, selected: u64, st: ^Style) ---
	rt_table       :: proc(f: rawptr, area: ^Rect, header: [^]string, nh: int, rows: [^]Row, nr: int, widths: [^]Cons, nw: int, st: ^Style) ---
	rt_barchart    :: proc(f: rawptr, area: ^Rect, bars: [^]Bar, n: int, bar_width: u16, st: ^Style) ---
	rt_scrollbar   :: proc(f: rawptr, area: ^Rect, content, position, viewport: u64, horizontal: i32, st: ^Style) ---
	rt_set_cursor  :: proc(f: rawptr, x, y: u16) ---
}

// Fixed-rate, input-aware frame pacing. Typical loop:
//   clock := clock_make(60)
//   for { ...update state...
//         draw(t, spec)                 // returns 1 and does nothing if nothing changed
//         for k := frame_wait(&clock); k != i32(Key.None); k = poll_key(0) { ...handle k... } }
Clock :: struct {
	next:   time.Tick,
	period: time.Duration,
}

clock_make :: proc(fps: int) -> Clock {
	period := time.Second / time.Duration(fps)
	return Clock{next = time.tick_add(time.tick_now(), period), period = period}
}

// Block until a key arrives or the next frame is due, whichever is first. Returns the key
// (Key.None on timeout). A key wakes the loop at once; no fixed sleep sits between input and redraw.
frame_wait :: proc(c: ^Clock) -> i32 {
	remaining := time.tick_diff(time.tick_now(), c.next)
	if remaining > 0 {
		ms := u32((remaining + time.Millisecond - 1) / time.Millisecond)
		if k := poll_key(ms); k != i32(Key.None) do return k
	}
	now := time.tick_now()
	if time.tick_diff(now, c.next) <= 0 { // deadline passed: advance, skipping ahead if late
		c.next = time.tick_add(c.next, c.period)
		if time.tick_diff(now, c.next) < 0 do c.next = time.tick_add(now, c.period)
	}
	return i32(Key.None)
}

// Test terminals: the screen as rows joined by '\n' (temp allocated).
test_screen :: proc(t: Term) -> string {
	n := rt_test_screen(t, nil, 0)
	if n < 0 do return ""
	buf := make([]u8, n, context.temp_allocator)
	rt_test_screen(t, raw_data(buf), n)
	return string(buf)
}

// Test terminals: foreground color of a cell as ratatui debug-prints it ("Red", "Reset").
test_fg :: proc(t: Term, x, y: u16) -> string {
	buf: [64]u8
	n := rt_test_fg(t, x, y, &buf[0], len(buf))
	if n < 0 || n > len(buf) do return ""
	return string(buf[:n])
}
