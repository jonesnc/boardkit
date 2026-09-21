package ratatui

// Walks a resolved spec tree and draws each node with one wrapper call. Also owns scroll/focus
// for widgets with "scroll": true and an "id".

import "base:runtime"
import "core:encoding/json"
import "core:strings"
import "core:unicode/utf8"

BOLD      :: u32(1)
ITALIC    :: u32(2)
UNDERLINE :: u32(4)
REVERSED  :: u32(8)
DIM       :: u32(16)

style_of :: proc(v: Value) -> Style {
	st := Style{fg = str_of(v, "fg"), bg = str_of(v, "bg")}
	if is_true(v, "bold") do st.mods |= BOLD
	if is_true(v, "italic") do st.mods |= ITALIC
	if is_true(v, "underline") do st.mods |= UNDERLINE
	return st
}

// ---- scrolling and focus ----

@(private)
Ui :: struct {
	scroll:     map[string]int,
	focus:      string,
	focusables: [dynamic]string, // registered during the current frame, in draw order
}

@(private)
ui: Ui

@(private)
ui_clear_focusables :: proc() {
	context.allocator = runtime.heap_allocator() // ui state lives for the process
	for f in ui.focusables do delete(f)
	clear(&ui.focusables)
}

@(private)
ui_has :: proc(id: string) -> bool {
	for f in ui.focusables do if f == id do return true
	return false
}

@(private)
ui_set_focus :: proc(id: string) {
	context.allocator = runtime.heap_allocator() // ui state lives for the process
	if ui.focus == id do return
	delete(ui.focus)
	ui.focus = strings.clone(id)
}

// After a frame: keep focus on a registered widget, else the first one.
@(private)
ui_fix_focus :: proc() {
	if !ui_has(ui.focus) do ui_set_focus(ui.focusables[0] if len(ui.focusables) > 0 else "")
}

// Reserve a scrollbar column and return (first visible row, content area). Non-scrollable widgets pass through.
@(private)
scroll_view :: proc(f: rawptr, area: Rect, v: Value, content_len: int, reserved: u16) -> (int, Rect) {
	idv, _ := get(v, "id")
	id, is_str := as_str(idv)
	if !is_true(v, "scroll") || !is_str do return 0, area
	context.allocator = runtime.heap_allocator() // ui state lives for the process
	visible := int(area.h - min(reserved, area.h))
	maxoff := max(content_len - visible, 0)
	append(&ui.focusables, strings.clone(id))
	if ui.focus == "" do ui_set_focus(id)
	off := min(ui.scroll[id] or_else 0, maxoff)
	if id not_in ui.scroll {
		ui.scroll[strings.clone(id)] = off
	} else {
		ui.scroll[id] = off // store the clamped value so keys act from what is on screen
	}
	if maxoff == 0 do return 0, area
	color := "cyan" if ui.focus == id else "darkgray"
	st := Style{fg = color}
	bar := Rect{area.x, area.y + reserved, area.w, area.h - min(reserved, area.h)}
	rt_scrollbar(f, &bar, u64(content_len), u64(off), u64(visible), 0, &st)
	return off, Rect{area.x, area.y, area.w - min(1, area.w), area.h}
}

// Handle a scroll/focus key. Returns true if consumed (a scrollable widget exists and the key is one of ours).
ui_handle_key :: proc(k: i32) -> bool {
	context.allocator = runtime.heap_allocator() // ui state lives for the process
	if len(ui.focusables) == 0 do return false
	cur := ui.focus if ui_has(ui.focus) else ui.focusables[0]
	step :: proc(cur: string, f: proc(o: int) -> int) {
		if cur not_in ui.scroll do ui.scroll[strings.clone(cur)] = 0
		ui.scroll[cur] = f(ui.scroll[cur])
	}
	switch {
	case k == -9:
		i := 0
		for f, j in ui.focusables do if f == cur do i = j
		ui_set_focus(ui.focusables[(i + 1) % len(ui.focusables)])
	case k == 'j' || k == -5: step(cur, proc(o: int) -> int { return o + 1 })
	case k == 'k' || k == -4: step(cur, proc(o: int) -> int { return max(o - 1, 0) })
	case k == -11:            step(cur, proc(o: int) -> int { return o + 10 })
	case k == -10:            step(cur, proc(o: int) -> int { return max(o - 10, 0) })
	case k == 'g' || k == -12: step(cur, proc(o: int) -> int { return 0 })
	case k == 'G' || k == -13: step(cur, proc(o: int) -> int { return max(int) / 2 }) // clamped at draw
	case:
		return false
	}
	dirty = true
	return true
}

// ---- rendering ----

@(private)
count_lines :: proc(s: string) -> int {
	// Rust str::lines(): a trailing newline does not start an extra line.
	if len(s) == 0 do return 0
	n := strings.count(s, "\n")
	return n if s[len(s) - 1] == '\n' else n + 1
}

@(private)
xy :: proc(p: Value) -> ([2]f64, bool) {
	a := as_array(p)
	if len(a) < 2 do return {}, false
	x, xok := as_f64(a[0])
	y, yok := as_f64(a[1])
	return {x, y}, xok && yok
}

@(private)
points_of :: proc(v: Value, key: string) -> [][2]f64 {
	out := make([dynamic][2]f64, context.temp_allocator)
	for p in array_of(v, key) do if q, ok := xy(p); ok do append(&out, q)
	return out[:]
}

@(private)
constraint_or_fill :: proc(s: string) -> Cons {
	c, _ := parse_constraint(s)
	return c
}

render :: proc(f: rawptr, area: Rect, v: Value) {
	area := area
	st := style_of(v)
	switch str_of(v, "type") {
	case "block":
		title := str_of(v, "title")
		inner: Rect
		rt_block(f, &area, &title, &st, &inner)
		if c, ok := get(v, "child"); ok do render(f, inner, c)
	case "paragraph":
		text := str_of(v, "text")
		off, a := scroll_view(f, area, v, count_lines(text), 0)
		rt_paragraph(f, &a, &text, &st, u16(min(off, 65535)))
	case "list":
		src := array_of(v, "items")
		items := make([dynamic]Item, context.temp_allocator)
		for it in src {
			#partial switch x in it {
			case json.String: append(&items, Item{text = string(x)})
			case json.Object: append(&items, Item{text = str_of(it, "text"), style = style_of(it)})
			}
		}
		off, a := scroll_view(f, area, v, len(items), 0)
		sel := i64(-1)
		if n, ok := uint_of(v, "selected"); ok && int(n) >= off do sel = i64(int(n) - off)
		shown := items[min(off, len(items)):]
		rt_list(f, &a, raw_data(shown), len(shown), &st, sel)
	case "gauge", "linegauge":
		ratio, _ := f64_of(v, "ratio")
		label := str_of(v, "label")
		if str_of(v, "type") == "gauge" {
			rt_gauge(f, &area, ratio, &label, &st)
		} else {
			rt_linegauge(f, &area, ratio, &label, &st)
		}
	case "chart":
		series := make([dynamic]Series, context.temp_allocator)
		x0, x1, y0, y1 := max(f64), min(f64), max(f64), min(f64)
		for s in array_of(v, "series") {
			pts := points_of(s, "data")
			for p in pts {
				x0, x1, y0, y1 = min(x0, p.x), max(x1, p.x), min(y0, p.y), max(y1, p.y)
			}
			append(&series, Series{name = str_of(s, "name"), style = style_of(s), pts = pts})
		}
		if x0 > x1 do x0, x1, y0, y1 = 0, 1, 0, 1
		if x0 == x1 do x1 = x0 + 1
		if y0 == y1 do y1 = y0 + 1
		bounds := [4]f64{x0, x1, y0, y1}
		xt, yt := str_of(v, "x_title"), str_of(v, "y_title")
		rt_chart(f, &area, raw_data(series), len(series), &xt, &yt, &bounds)
	case "calendar":
		y, m := i32(2026), u8(1)
		yv, yok := get(v, "year")
		yi, yint := yv.(json.Integer)
		mu, mok := uint_of(v, "month")
		if yok && yint && mok do y, m = i32(yi), u8(clamp(mu, 1, 12))
		days := make([dynamic]u8, context.temp_allocator)
		for d in array_of(v, "highlight") do if n, ok := as_uint(d); ok && n < 256 do append(&days, u8(n))
		rt_calendar(f, &area, y, m, raw_data(days), len(days), &st)
	case "canvas":
		bounds :: proc(v: Value, k: string) -> [2]f64 {
			a := array_of(v, k)
			b := [2]f64{0, 100}
			if len(a) > 0 do if x, ok := as_f64(a[0]); ok do b[0] = x
			if len(a) > 1 do if x, ok := as_f64(a[1]); ok do b[1] = x
			return b
		}
		n :: proc(s: Value, k: string) -> f64 { x, _ := f64_of(s, k); return x }
		shapes := make([dynamic]Shape, context.temp_allocator)
		for s in array_of(v, "shapes") {
			sh := Shape{style = style_of(s)}
			switch str_of(s, "shape") {
			case "line":   sh.kind, sh.a, sh.b, sh.c, sh.d = 0, n(s, "x1"), n(s, "y1"), n(s, "x2"), n(s, "y2")
			case "rect":   sh.kind, sh.a, sh.b, sh.c, sh.d = 1, n(s, "x"), n(s, "y"), n(s, "w"), n(s, "h")
			case "circle": sh.kind, sh.a, sh.b, sh.c = 2, n(s, "x"), n(s, "y"), n(s, "r")
			case "points": sh.kind, sh.pts = 3, points_of(s, "coords")
			case "map":    sh.kind, sh.a = 4, 1 if str_of(s, "resolution") == "high" else 0
			case "text":   sh.kind, sh.a, sh.b, sh.text = 5, n(s, "x"), n(s, "y"), str_of(s, "text")
			case:          continue
			}
			append(&shapes, sh)
		}
		xb, yb := bounds(v, "x_bounds"), bounds(v, "y_bounds")
		rt_canvas(f, &area, &xb, &yb, raw_data(shapes), len(shapes))
	case "logo":
		rt_logo(f, &area, 1 if str_of(v, "size") == "small" else 0)
	case "mascot":
		rt_mascot(f, &area)
	case "sparkline":
		data := make([dynamic]u64, context.temp_allocator)
		for d in array_of(v, "data") do if n, ok := as_uint(d); ok do append(&data, n)
		rt_sparkline(f, &area, raw_data(data), len(data), &st)
	case "tabs":
		titles := strings_of(v, "titles")
		sel, _ := uint_of(v, "selected")
		rt_tabs(f, &area, raw_data(titles), len(titles), sel, &st)
	case "table":
		rows := make([dynamic]Row, context.temp_allocator)
		cells :: proc(a: Value) -> []string {
			out := make([dynamic]string, context.temp_allocator)
			for e in as_array(a) do if s, ok := as_str(e); ok do append(&out, s)
			return out[:]
		}
		for r in array_of(v, "rows") {
			#partial switch _ in r {
			case json.Array:  append(&rows, Row{cells = cells(r)})
			case json.Object: c, _ := get(r, "cells"); append(&rows, Row{cells = cells(c), style = style_of(r)})
			}
		}
		header := strings_of(v, "header")
		off, a := scroll_view(f, area, v, len(rows), 1 if len(header) > 0 else 0)
		widths := make([dynamic]Cons, context.temp_allocator)
		for w in strings_of(v, "widths") do append(&widths, constraint_or_fill(w))
		shown := rows[min(off, len(rows)):]
		rt_table(f, &a, raw_data(header), len(header), raw_data(shown), len(shown), raw_data(widths), len(widths), &st)
	case "barchart":
		bars := make([dynamic]Bar, context.temp_allocator)
		for p in array_of(v, "data") {
			pa := as_array(p)
			if len(pa) < 2 do continue
			l, lok := as_str(pa[0])
			n, nok := as_uint(pa[1])
			if lok && nok do append(&bars, Bar{label = l, value = n})
		}
		bw, bok := uint_of(v, "bar_width")
		rt_barchart(f, &area, raw_data(bars), len(bars), u16(bw) if bok else 3, &st)
	case "scrollbar":
		content, _ := uint_of(v, "content")
		pos, _ := uint_of(v, "position")
		rt_scrollbar(f, &area, content, pos, 0, 1 if str_of(v, "orientation") == "horizontal" else 0, &st)
	case "input":
		text, title := str_of(v, "text"), str_of(v, "title")
		inner: Rect
		rt_block(f, &area, &title, &st, &inner) // Paragraph.style covers the border too
		rt_paragraph(f, &inner, &text, &st, 0)
		if is_true(v, "focused") {
			cur, ok := uint_of(v, "cursor")
			if !ok do cur = u64(utf8.rune_count_in_string(text))
			x := inner.x + u16(min(cur, u64(max(int(inner.w) - 1, 0))))
			rt_set_cursor(f, x, inner.y)
		}
	case "popup":
		full: Rect
		rt_frame_area(f, &full) // overlay: centered on the whole frame, wherever it sits in the tree
		w, wok := uint_of(v, "width")
		h, hok := uint_of(v, "height")
		w = min(w if wok else 50, 100)
		h = min(h if hok else 30, 100)
		pw, ph := u16(u64(full.w) * w / 100), u16(u64(full.h) * h / 100)
		r := Rect{full.x + (full.w - pw) / 2, full.y + (full.h - ph) / 2, pw, ph}
		rt_clear(f, &r)
		title := str_of(v, "title")
		inner: Rect
		rt_block(f, &r, &title, &st, &inner)
		if c, ok := get(v, "child"); ok do render(f, inner, c)
	case "vstack", "hstack":
		kids := array_of(v, "children")
		if len(kids) == 0 do return
		sizes := strings_of(v, "sizes")
		cons := make([]Cons, len(kids), context.temp_allocator)
		for k, i in kids {
			s := sizes[i] if i < len(sizes) else str_of(k, "size")
			cons[i] = constraint_or_fill(s) if s != "" else Cons{0, 1}
		}
		areas := make([]Rect, len(kids), context.temp_allocator)
		rt_layout(&area, 1 if str_of(v, "type") == "vstack" else 0, raw_data(cons), len(cons), raw_data(areas))
		for k, i in kids do render(f, areas[i], k)
	}
}
