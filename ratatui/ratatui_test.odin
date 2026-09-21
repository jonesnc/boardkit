package ratatui

// Ported from the Rust shim's tests. Run: odin test ratatui -extra-linker-flags:"-lgcc_s -lm -lpthread -ldl" -define:ODIN_TEST_THREADS=1
// (one thread: the tests share package globals).

import "core:encoding/json"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:log"
import "core:testing"
import "core:time"

@(private = "file")
j :: proc(s: string) -> Value {
	v, err := parse_json(s, context.temp_allocator)
	assert(err == nil, s)
	return v
}

@(private = "file")
bad :: proc(s: string) -> string {
	return validate_spec(j(s))
}

@(test)
every_prefix_never_panics_and_final_matches :: proc(t: ^testing.T) {
	full := `{"type":"vstack","children":[{"type":"paragraph","text":"he\"llo"},{"type":"gauge","ratio":0.5,"label":"x"}]}`
	got := 0
	for i in 0 ..= len(full) {
		if _, ok := parse_partial(full[:i]); ok do got += 1
	}
	testing.expectf(t, got > len(full) / 2, "only %d prefixes parsed", got)
	v, ok := parse_partial(full)
	testing.expect(t, ok && equal(v, j(full)))
}

@(test)
partial_string_and_dangling_key :: proc(t: ^testing.T) {
	v, ok := parse_partial(`{"type":"paragraph","te`)
	testing.expect(t, ok && str_of(v, "type") == "paragraph")
	v, ok = parse_partial(`{"type":"paragraph","text":"hel`)
	testing.expect(t, ok && str_of(v, "text") == "hel")
}

@(test)
state_each_if_item :: proc(t: ^testing.T) {
	st: Value
	defer destroy(st)
	set_ptr(&st, "/cpu", json.Float(0.5))
	set_ptr(&st, "/procs", clone(j(`[{"n":"a"},{"n":"b"}]`)))
	set_ptr(&st, "/procs/1/n", json.String(strings.clone("B")))
	set_ptr(&st, "/show", json.Boolean(false))
	spec := j(`{"type":"vstack","children":[
		{"type":"gauge","ratio":{"$state":"/cpu"},"label":{"$state":"/missing"}},
		{"$each":"/procs","template":{"type":"paragraph","text":{"$item":"/n"}}},
		{"type":"popup","$if":"/show","child":{"type":"paragraph","text":"x"}}]}`)
	r, _ := resolve(spec, st, nil)
	kids := array_of(r, "children")
	testing.expect_value(t, len(kids), 3) // popup hidden, 2 each-items + gauge
	ratio, _ := f64_of(kids[0], "ratio")
	testing.expect_value(t, ratio, 0.5)
	testing.expect(t, !has(kids[0], "label"), "missing path drops prop")
	testing.expect_value(t, str_of(kids[2], "text"), "B")
	set_ptr(&st, "/show", json.Boolean(true))
	r, _ = resolve(spec, st, nil)
	testing.expect_value(t, len(array_of(r, "children")), 4)
}

@(test)
root_set_replaces_all :: proc(t: ^testing.T) {
	st := clone(j(`{"a":1}`))
	defer destroy(st)
	set_ptr(&st, "/", clone(j(`{"b":2}`)))
	testing.expect(t, equal(st, j(`{"b":2}`)))
}

@(test)
load_validates_each_template :: proc(t: ^testing.T) {
	testing.expect(t, bad(`{"$each":"/x","template":{"type":"nope"}}`) != "")
	testing.expect(t, bad(`{"type":"vstack","children":[{"$each":"/x","template":{"type":"paragraph","text":"t"}}]}`) == "")
}

@(test)
all_shipped_specs_validate :: proc(t: ^testing.T) {
	root, _ := filepath.join({#directory, ".."}, context.temp_allocator)
	n := 0
	for dir in ([]string{"examples/boards"}) {
		d, _ := filepath.join({root, dir}, context.temp_allocator)
		entries, _ := os.read_all_directory_by_path(d, context.temp_allocator)
		for e in entries {
			if filepath.ext(e.name) != ".json" do continue
			v, err := load_file(e.fullpath)
			testing.expectf(t, err == "", "%s", err)
			destroy(v)
			n += 1
		}
	}
	testing.expectf(t, n >= 4, "found only %d specs", n)
}

@(test)
type_errors_are_reported :: proc(t: ^testing.T) {
	has_msg :: proc(t: ^testing.T, e, want: string) {
		testing.expectf(t, strings.contains(e, want), "%q does not contain %q", e, want)
	}
	has_msg(t, bad(`{"type":"gauge","ratio":"half"}`), "ratio must be float 0..1 (got string)")
	has_msg(t, bad(`{"type":"gauge","ratio":1.5}`), "float 0..1")
	has_msg(t, bad(`{"type":"paragraph","text":"x","colour":"red"}`), `no prop "colour"`)
	has_msg(t, bad(`{"type":"paragraph","text":"x","fg":"notacolor"}`), "fg must be")
	has_msg(t, bad(`{"type":"vstack","children":[],"sizes":["wide"]}`), "sizes must be")
	has_msg(t, bad(`{"type":"scrollbar","content":1,"position":0,"orientation":"diagonal"}`), "orientation")
	testing.expect(t, bad(`{"type":"gauge","ratio":{"$state":"/x"},"fg":"green","size":"length:3"}`) == "")
	testing.expect(t, bad(`{"type":"gauge","ratio":0.5,"fg":{"$pick":{"of":{"$state":"/n"},"rules":[[">0","red"]],"else":"green"}}}`) == "")
	testing.expect(t, bad(`{"type":"table","rows":[["a","b"]],"widths":["fill:2","length:6"]}`) == "")
}

@(test)
pick_rules :: proc(t: ^testing.T) {
	st := j(`{"pct": "94%", "n": 40, "name": "bob"}`)
	rules :: proc(st: Value, spec: string) -> string {
		r, _ := resolve(j(spec), st, nil)
		s, _ := as_str(r)
		return s
	}
	testing.expect_value(t, rules(st, `{"$pick":{"of":{"$state":"/pct"},"rules":[[">=90","red"],[">=70","yellow"]],"else":"green"}}`), "red")
	testing.expect_value(t, rules(st, `{"$pick":{"of":{"$state":"/n"},"rules":[[">=90","red"],[">=70","yellow"]],"else":"green"}}`), "green")
	testing.expect_value(t, rules(st, `{"$pick":{"of":{"$state":"/n"},"rules":[["<50","low"]],"else":"hi"}}`), "low")
	testing.expect_value(t, rules(st, `{"$pick":{"of":{"$state":"/name"},"rules":[["==bob","yes"]],"else":"no"}}`), "yes")
	r, _ := resolve(j(`{"type":"paragraph","text":"x","fg":{"$pick":{"of":{"$state":"/pct"},"rules":[[">=90","red"]]}}}`), st, nil)
	testing.expect_value(t, str_of(r, "fg"), "red")
}

@(private = "file")
test_draw :: proc(term: Term, v: Value) -> []string {
	ui_clear_focusables()
	job := Frame_Job{ctx = context, tree = v}
	rt_frame(term, frame_cb, &job)
	ui_fix_focus()
	return strings.split(test_screen(term), "\n", context.temp_allocator)
}

@(test)
colored_rows_validate_and_render :: proc(t: ^testing.T) {
	spec := j(`{"type":"table","header":["D","U"],"rows":[{"cells":["disk1","94%"],"fg":"red"},["disk2","48%"]]}`)
	testing.expect(t, validate_spec(spec) == "")
	term := test_init(20, 4)
	defer restore(term)
	rows := test_draw(term, spec)
	testing.expect(t, strings.contains(rows[1], "disk1"))
	testing.expect_value(t, test_fg(term, 0, 1), "Red")
	testing.expect(t, test_fg(term, 0, 2) != "Red")
}

@(test)
scroll_needs_id :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(bad(`{"type":"list","items":["a"],"scroll":true}`), `needs a string "id"`))
	testing.expect(t, bad(`{"type":"list","items":["a"],"scroll":true,"id":"l"}`) == "")
}

@(test)
chart_and_linegauge_validate :: proc(t: ^testing.T) {
	testing.expect(t, bad(`{"type":"chart","series":[{"name":"a","fg":"cyan","data":[[0,1],[1,2.5]]}]}`) == "")
	testing.expect(t, bad(`{"type":"chart","series":{"$state":"/s"}}`) == "")
	testing.expect(t, bad(`{"type":"chart","series":[{"data":[["x",1]]}]}`) != "")
	testing.expect(t, bad(`{"type":"linegauge","ratio":0.5,"label":"x"}`) == "")
	testing.expect(t, bad(`{"type":"linegauge","ratio":2}`) != "")
}

@(test)
new_widgets_validate :: proc(t: ^testing.T) {
	testing.expect(t, bad(`{"type":"calendar","year":2026,"month":9,"highlight":[1,2]}`) == "")
	testing.expect(t, bad(`{"type":"calendar","year":2026}`) != "")
	testing.expect(t, bad(`{"type":"canvas","shapes":[{"shape":"line","x1":0,"y1":0,"x2":1,"y2":1}]}`) == "")
	testing.expect(t, bad(`{"type":"logo","size":"small"}`) == "")
	testing.expect(t, bad(`{"type":"logo","size":"huge"}`) != "")
	testing.expect(t, bad(`{"type":"mascot"}`) == "")
}

@(test)
scroll_and_focus :: proc(t: ^testing.T) {
	spec := j(`{"type":"hstack","children":[
		{"type":"list","items":["row0","row1","row2","row3","row4","row5","row6","row7","row8","row9"],"scroll":true,"id":"a"},
		{"type":"list","items":["row0","row1","row2","row3","row4","row5","row6","row7","row8","row9"],"scroll":true,"id":"b"}]}`)
	term := test_init(40, 4)
	defer restore(term)
	ui_clear_focusables()
	testing.expect(t, !ui_handle_key('j'), "no scrollables registered yet: key not consumed")
	s0 := test_draw(term, spec)
	testing.expect(t, strings.contains(s0[0], "row0"))
	testing.expect(t, ui_handle_key('j') && ui_handle_key('j'))
	s1 := test_draw(term, spec)
	testing.expectf(t, strings.has_prefix(s1[0], "row2"), "focused list a scrolled: %q", s1[0])
	testing.expectf(t, strings.contains(s1[0], "row0"), "list b (unfocused) unchanged: %q", s1[0])
	testing.expect(t, ui_handle_key(-9)) // Tab -> b
	testing.expect(t, ui_handle_key('G'))
	s2 := test_draw(term, spec)
	testing.expect(t, strings.has_prefix(s2[0], "row2"), "a unchanged")
	testing.expectf(t, strings.contains(s2[3], "row9"), "b jumped to the end, clamped: %q", s2[3])
	testing.expect(t, ui_handle_key('g'))
	testing.expect(t, strings.contains(test_draw(term, spec)[0], "row0"))
	testing.expect(t, !ui_handle_key('x'), "other keys pass through")
}

@(test)
parse_is_strict_and_keeps_big_numbers :: proc(t: ^testing.T) {
	_, err := parse_json(`{"a":1} xyz`, context.temp_allocator)
	testing.expect(t, err != nil, "trailing garbage is an error")
	v, _ := parse_json(`18446744073709551615`, context.temp_allocator)
	f, _ := as_f64(v)
	testing.expect(t, f > 1e19, "no wrap to a negative integer")
	v, _ = parse_json(`[3, 3.0, 2.5]`, context.temp_allocator)
	_, is_int := as_array(v)[1].(json.Integer)
	testing.expect(t, is_int, "whole floats become Integer")
}

@(test)
json_round_trip :: proc(t: ^testing.T) {
	src := `{"a":[1,2.5,"x\n\"y\"",true,null],"b":{"c":-3}}`
	out := to_json(j(src), context.temp_allocator)
	testing.expect_value(t, out, src)
}

// Timing only; always passes. Logs resolve and resolve+render+diff cost per frame.
@(test)
frame_cost :: proc(t: ^testing.T) {
	path, _ := filepath.join({#directory, "..", "examples", "boards", "bindings.json"}, context.temp_allocator)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	spec, _ := get(j(string(data)), "spec")
	st := j(`{"d": {"sel": 1, "confirm": true, "cpu": 0.5, "cpu_label": "CPU 50%", "popup_text": "Kill?",
		"names": ["nginx","postgres","redis","odin-demo"],
		"procs": [{"line":"nginx pid 1 mem 100 MB"},{"line":"postgres pid 2 mem 200 MB"},{"line":"redis pid 3 mem 300 MB"},{"line":"odin pid 4 mem 400 MB"}]}}`)
	for size in ([][2]u16{{120, 40}, {250, 70}}) {
		term := test_init(size.x, size.y)
		defer restore(term)
		n := 3000
		context.temp_allocator = scratch()
		start := time.tick_now()
		for _ in 0 ..< n {
			_, _ = resolve(spec, st, nil)
			free_all(context.temp_allocator)
		}
		res := time.tick_since(start) / time.Duration(n)
		start = time.tick_now()
		for _ in 0 ..< n {
			tree, _ := resolve(spec, st, nil)
			job := Frame_Job{ctx = context, tree = tree}
			rt_frame(term, frame_cb, &job)
			free_all(context.temp_allocator)
		}
		ren := time.tick_since(start) / time.Duration(n)
		log.infof("%dx%d: resolve %v  resolve+render+diff %v", size.x, size.y, res, ren)
	}
}
