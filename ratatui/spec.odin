package ratatui

// Live state, spec files with hot reload, an external state file, and the public draw API.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:time"

Object :: json.Object

@(private) state: Value
@(private) state_ver: u64
@(private) dirty: bool // resize or scroll key: redraw even if spec and state are unchanged
@(private) last_key: [3]u64 // (spec, generation, state_ver) of the last frame drawn
@(private) last_err: cstring

// Scratch memory for one public call (resolve trees, widget arrays, messages). Kept apart from the
// caller's temp allocator so a draw never frees what the caller put there.
@(private) scratch_arena: virtual.Arena

@(private)
scratch :: proc() -> runtime.Allocator {
	if scratch_arena.curr_block == nil do _ = virtual.arena_init_growing(&scratch_arena)
	return virtual.arena_allocator(&scratch_arena)
}

@(private)
set_err :: proc(msg: string) {
	delete(last_err)
	last_err = strings.clone_to_cstring(msg)
}

// Message for the last failed call (validate, spec_load, state_*). NULL if none.
last_error :: proc() -> cstring {
	return last_err
}

@(private) catalog_prompt_c: cstring

// The catalog as JSON. Static; do not free.
catalog_json :: proc() -> cstring {
	return cstring(raw_data(CATALOG_TEXT + "\x00"))
}

// A system-prompt fragment telling an LLM how to emit a valid spec. Static; do not free.
catalog_prompt :: proc() -> cstring {
	if catalog_prompt_c == nil {
		context.temp_allocator = scratch()
		defer free_all(context.temp_allocator)
		catalog_prompt_c = strings.clone_to_cstring(catalog_prompt_text(context.temp_allocator))
	}
	return catalog_prompt_c
}

// Validate a spec against the catalog. Returns 0 if valid, -1 if invalid (see last_error), -2 on bad JSON/args.
validate :: proc(spec: cstring) -> i32 {
	if spec == nil do return -2
	context.temp_allocator = scratch()
	defer free_all(context.temp_allocator)
	v, err := parse_json(string(spec), context.temp_allocator)
	if err != nil {
		set_err(fmt.tprintf("bad JSON: %v", err))
		return -2
	}
	if e := validate_spec(v); e != "" {
		set_err(e)
		return -1
	}
	return 0
}

// Handle a key for scrollable widgets. Returns 1 if consumed (redraw is scheduled), else 0.
// Call before your own key handling: Tab focus, j/k/arrows, PgUp/PgDn, g/G, Home/End.
ui_key :: proc(k: i32) -> i32 {
	return 1 if ui_handle_key(k) else 0
}

// ---- state ----

@(private)
state_set :: proc(path: cstring, val: Value) -> i32 {
	if path == nil {
		destroy(val)
		return -1
	}
	p := string(path)
	v := val
	norm(&v)
	cur, found := Value(state), true
	if !(p == "" || p == "/") do cur, found = pointer(state, p)
	if found && equal(cur, v) {
		destroy(v)
		return 0
	}
	set_ptr(&state, p, v)
	state_ver += 1
	return 0
}

// Set a number at a JSON-pointer path, e.g. "/cpu". Returns 0, or -1 on bad args.
state_set_f64 :: proc(path: cstring, v: f64) -> i32 {
	return state_set(path, json.Float(v))
}

// Set a string at a path.
state_set_str :: proc(path: cstring, v: cstring) -> i32 {
	if v == nil do return -1
	return state_set(path, json.String(strings.clone(string(v))))
}

// Set any JSON value at a path. Path "/" replaces the whole state. Returns 0, -1 bad args, -2 bad JSON.
state_set_json :: proc(path: cstring, text: cstring) -> i32 {
	if text == nil do return -1
	v, err := parse_json(string(text))
	if err != nil {
		destroy(v)
		set_err(fmt.tprintf("bad JSON: %v", err))
		return -2
	}
	return state_set(path, v)
}

// Read a copy-free view of the state (valid until the next state change).
state_get :: proc(path: string) -> (Value, bool) {
	return pointer(state, path)
}

// ---- external state file: any process writes JSON, reloaded when it changes ----

@(private) state_file: string
@(private) state_file_seen: time.Time

@(private)
mtime_of :: proc(path: string) -> time.Time {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil do return {}
	return fi.modification_time
}

// Watch a JSON file as the whole state. Loaded now and re-read on change (checked on each draw).
// Writers should replace the file atomically (write temp file, then rename). Returns 0, or -1 on
// a bad path, -2 if the first load fails (see last_error).
state_watch :: proc(path: cstring) -> i32 {
	if path == nil do return -1
	context.temp_allocator = scratch()
	defer free_all(context.temp_allocator)
	delete(state_file)
	state_file = strings.clone(string(path))
	state_file_seen = {}
	return 0 if poll_state_file() else -2
}

// Reload the watched state file if its mtime changed. Returns false only if a load failed.
@(private)
poll_state_file :: proc() -> bool {
	if state_file == "" do return true
	now := mtime_of(state_file)
	if now == state_file_seen do return true
	state_file_seen = now
	data, rerr := os.read_entire_file(state_file, context.temp_allocator)
	if rerr != nil {
		set_err(fmt.tprintf("%s: %v", state_file, rerr))
		return false
	}
	v, err := parse_json(string(data))
	if err != nil {
		destroy(v)
		set_err(fmt.tprintf("%s: bad JSON: %v", state_file, err)) // keep the old state; a half-written file is retried on the next change
		return false
	}
	norm(&v)
	if equal(state, v) {
		destroy(v)
	} else {
		destroy(state)
		state = v
		state_ver += 1
	}
	return true
}

// ---- drawing ----

@(private)
Frame_Job :: struct {
	ctx:    runtime.Context,
	tree:   Value,
	banner: string,
}

@(private)
frame_cb :: proc "c" (f: rawptr, ud: rawptr) {
	job := (^Frame_Job)(ud)
	context = job.ctx
	area: Rect
	rt_frame_area(f, &area)
	render(f, area, job.tree)
	if job.banner != "" && area.h > 0 {
		row := Rect{area.x, area.y + area.h - 1, area.w, 1}
		rt_clear(f, &row)
		msg := fmt.tprintf(" ! %s", job.banner)
		st := Style{fg = "white", bg = "red"}
		rt_paragraph(f, &row, &msg, &st, 0)
	}
}

// Resolve bindings against the state and draw. Error banner on the bottom row: a failed spec
// reload first, else the first source error in /_errors. Returns 0, or -3 on IO error.
draw_value :: proc(t: Term, v: Value, spec_err: string) -> i32 {
	context.temp_allocator = scratch()
	defer free_all(context.temp_allocator)
	tree, ok := resolve(v, state, nil)
	if !ok do return 0
	banner := spec_err
	if banner == "" {
		e, _ := pointer(state, "/_errors/0")
		banner, _ = as_str(e)
	}
	ui_clear_focusables()
	job := Frame_Job{ctx = context, tree = tree, banner = banner}
	rc := rt_frame(t, frame_cb, &job)
	ui_fix_focus()
	return 0 if rc == 0 else -3
}

// Draw a JSON UI spec (no bindings needed). Returns 0 on success, -1 on bad args, -2 on bad JSON, -3 on IO error.
draw_json :: proc(t: Term, spec: cstring) -> i32 {
	if t == nil || spec == nil do return -1
	context.temp_allocator = scratch()
	v, err := parse_json(string(spec), context.temp_allocator)
	if err != nil do return -2
	last_key = {}
	return draw_value(t, v, "") // frees v with the scratch arena
}

// ---- spec files ----

Spec_State :: struct {
	generation: u64,
	err:        string,
	path:       string,
	mtime:      time.Time,
	value:      Value,
}

Spec :: ^Spec_State

@(private)
load_file :: proc(path: string) -> (Value, string) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil do return nil, fmt.tprintf("%s: %v", path, rerr)
	v, err := parse_json(string(data))
	if err != nil {
		destroy(v)
		return nil, fmt.tprintf("%s: bad JSON: %v", path, err)
	}
	// A board file wraps the spec: {"sources": [...], "spec": {...}}. Load just the spec.
	if !has(v, "type") && has(v, "spec") {
		o := v.(Object)
		inner := o["spec"]
		o["spec"] = nil
		destroy(v)
		v = inner
	}
	if e := validate_spec(v); e != "" {
		destroy(v)
		return nil, fmt.tprintf("%s: %s", path, e)
	}
	return v, ""
}

// Load and validate a spec file. Returns nil on error (see last_error).
spec_load :: proc(path: cstring) -> Spec {
	if path == nil do return nil
	context.temp_allocator = scratch()
	defer free_all(context.temp_allocator)
	p := string(path)
	v, err := load_file(p)
	if err != "" {
		set_err(err)
		return nil
	}
	s := new(Spec_State)
	s^ = {path = strings.clone(p), mtime = mtime_of(p), value = v}
	return s
}

spec_free :: proc(s: Spec) {
	if s == nil do return
	destroy(s.value)
	delete(s.path)
	delete(s.err)
	free(s)
}

// Draw a loaded spec with current state. If the file changed on disk, reload first; a bad reload
// keeps the old spec and shows a banner. Returns 0 if drawn, 1 if skipped because nothing changed
// since the last draw, -1 bad args, -3 IO error.
draw :: proc(t: Term, sp: Spec) -> i32 {
	if t == nil || sp == nil do return -1
	context.temp_allocator = scratch()
	defer free_all(context.temp_allocator)
	poll_state_file()
	if now := mtime_of(sp.path); now != sp.mtime {
		sp.mtime = now
		v, err := load_file(sp.path)
		delete(sp.err)
		sp.err = ""
		if err == "" {
			destroy(sp.value)
			sp.value = v
		} else {
			sp.err = fmt.aprintf("reload failed: %s", err)
			set_err(err)
		}
		sp.generation += 1 // repaint (a failed reload shows its banner)
	}
	if take_resized() != 0 do dirty = true
	key := [3]u64{u64(uintptr(sp)), sp.generation, state_ver}
	if !dirty && last_key == key {
		return 1
	}
	dirty = false
	rc := draw_value(t, sp.value, sp.err)
	last_key = key
	return rc
}
