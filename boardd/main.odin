package main

// boardd: watches a boards/ directory. Each `<name>.json` is a board:
//   { "sources": [{"cmd": "...", "every": 5, "into": "/ptr"}], "spec": {...}, "direction": "right" }
// For every board it runs the sources (shell commands printing JSON) into a state file and keeps
// one herdr pane running the viewer on it. Adding, editing or deleting the file adds, updates or
// removes the board. A pane you close by hand stays closed until you edit the file again.
//
// usage: boardd [root] [extra board dir...] | boardd --check [dir...] | boardd view <spec-or-board.json> [state.json]   (root defaults to the repo that holds this binary, <root>/boardd/boardd; boards live in <root>/boards)

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "core:time"
import rt "../ratatui"

Value :: rt.Value

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	mallopt :: proc(param: i32, value: i32) -> i32 ---
}

M_MMAP_THRESHOLD :: -3
M_ARENA_MAX      :: -8

// Shared by a board's source threads. Never freed: threads may outlive the board (a few bytes per reload).
Stop :: struct {
	flag: bool,
}

stopped :: proc(s: ^Stop) -> bool {
	return sync.atomic_load(&s.flag)
}

Board :: struct {
	mtime:       time.Time,
	path:        string, // the file it was loaded from; a move relaunches the viewer
	stop:        ^Stop,
	state:       Value,
	direction:   string,
	ratio:       Maybe(f64),
	parent:      Maybe(string),
	tab:         Maybe(string),
	workspace:   Maybe(string),
	wants_herdr: bool,
	wants_boardd: bool,
	last_data:   time.Tick,
	enabled:     bool,
	pane:        Maybe(string),
	dismissed:   bool,
	verify_pane: bool, // an adopted pane: relaunch the viewer if it is not actually running
	ready_at:    time.Tick,
}

// A source thread's report. Strings and value are heap-owned; the receiver frees them.
Msg :: struct {
	board:  string,
	kind:   enum {Data, Err},
	into:   string, // Data
	value:  Value,  // Data
	idx:    int,    // Err
	msg:    Maybe(string), // Err: nil = source ok
}

msgs: chan.Chan(Msg)
wake: sync.Sema // posted on every send, so the main loop sleeps until data arrives

post :: proc(m: Msg) {
	chan.send(msgs, m)
	sync.sema_post(&wake)
}

log :: proc(format: string, args: ..any) {
	fmt.printfln("[boardd] %s", fmt.tprintf(format, ..args))
}

// ---- processes ----

// Run a command; returns (exit code, stdout, stderr). code = -1 if it could not start.
// Not os.process_exec: that busy-polls its pipes while the child runs, burning a core per slow
// source. Here stdout is a blocking pipe and stderr goes to a temp file (no pipe to deadlock on).
run :: proc(cmd: []string, dir := "", allocator := context.temp_allocator) -> (code: int, out, errout: string) {
	r, w, perr := os.pipe()
	if perr != nil do return -1, "", fmt.aprint(perr, allocator = allocator)
	ef, terr := os.create_temp_file("", "boardd-stderr-*")
	if terr != nil {
		os.close(r)
		os.close(w)
		return -1, "", fmt.aprint(terr, allocator = allocator)
	}
	os.remove(os.name(ef)) // unlinked now, so a killed boardd leaves nothing in /tmp
	defer os.close(ef)
	p, err := os.process_start({command = cmd, working_dir = dir, stdout = w, stderr = ef})
	os.close(w)
	if err != nil {
		os.close(r)
		return -1, "", fmt.aprint(err, allocator = allocator)
	}
	buf := make([dynamic]u8, allocator)
	chunk: [8192]u8
	for {
		n, rerr := os.read(r, chunk[:])
		if n > 0 do append(&buf, ..chunk[:n])
		if n <= 0 || rerr != nil do break
	}
	os.close(r)
	st, _ := os.process_wait(p)
	os.seek(ef, 0, .Start)
	ebuf: [512]u8 // only the first line is reported
	en, _ := os.read(ef, ebuf[:])
	code = st.exit_code if st.exited else -1
	return code, string(buf[:]), strings.clone(string(ebuf[:max(en, 0)]), allocator)
}

herdr :: proc(args: ..string) -> (Value, bool) {
	cmd := make([]string, len(args) + 1, context.temp_allocator)
	cmd[0] = "herdr"
	copy(cmd[1:], args)
	code, out, _ := run(cmd)
	if code != 0 do return nil, false
	v, _ := rt.parse_json(out, context.temp_allocator)
	r, _ := rt.get(v, "result")
	return r, true
}

// ---- herdr placement ----

board_panes :: proc() -> map[string]string {
	m := make(map[string]string, context.temp_allocator)
	r, ok := herdr("pane", "list")
	if !ok do return m
	for p in rt.array_of(r, "panes") {
		l, id := rt.str_of(p, "label"), rt.str_of(p, "pane_id")
		if id != "" && strings.has_prefix(l, "board:") do m[l[len("board:"):]] = id
	}
	return m
}

ratio_arg :: proc(r: Maybe(f64)) -> (s: string, ok: bool) {
	x := r.? or_return
	return fmt.tprintf("%v", x), true
}

// Find or create the tab `tab` in `workspace` (label or id; default: the focused workspace) and return a pane for a board.
// A new tab hands back its root pane; an existing tab is split (preferring a pane that already holds a board).
place_in_tab :: proc(workspace: Maybe(string), tab, direction: string, ratio: Maybe(f64), root: string) -> (pane: string, ok: bool) {
	wl := herdr("workspace", "list") or_return
	wss := rt.array_of(wl, "workspaces")
	ws: Value
	found := false
	if w, has := workspace.?; has {
		for x in wss do if rt.str_of(x, "workspace_id") == w || rt.str_of(x, "label") == w {
			ws, found = x, true
			break
		}
	} else {
		for x in wss do if rt.is_true(x, "focused") {
			ws, found = x, true
			break
		}
		if !found && len(wss) > 0 do ws, found = wss[0], true
	}
	if !found {
		log("workspace %v not found", workspace)
		return "", false
	}
	ws_id := rt.str_of(ws, "workspace_id")
	tl := herdr("tab", "list") or_return
	tab_id := ""
	for t in rt.array_of(tl, "tabs") do if rt.str_of(t, "label") == tab && rt.str_of(t, "workspace_id") == ws_id {
		tab_id = rt.str_of(t, "tab_id")
		break
	}
	if tab_id == "" {
		r := herdr("tab", "create", "--workspace", ws_id, "--label", tab, "--cwd", root, "--no-focus") or_return
		rp, _ := rt.get(r, "root_pane")
		id := rt.str_of(rp, "pane_id")
		return id, id != ""
	}
	pl := herdr("pane", "list") or_return
	parent := ""
	for p in rt.array_of(pl, "panes") {
		if rt.str_of(p, "tab_id") != tab_id do continue
		if parent == "" do parent = rt.str_of(p, "pane_id")
		if strings.has_prefix(rt.str_of(p, "label"), "board:") {
			parent = rt.str_of(p, "pane_id")
			break
		}
	}
	if parent == "" do return "", false
	return split_pane(parent, direction, ratio, root)
}

split_pane :: proc(parent: Maybe(string), direction: string, ratio: Maybe(f64), root: string) -> (pane: string, ok: bool) {
	args := make([dynamic]string, context.temp_allocator)
	append(&args, "pane", "split")
	if p, has := parent.?; has do append(&args, "--pane", p)
	append(&args, "--direction", direction, "--cwd", root)
	if r, has := ratio_arg(ratio); has do append(&args, "--ratio", r)
	r := herdr(..args[:]) or_return
	p, _ := rt.get(r, "pane")
	id := rt.str_of(p, "pane_id")
	return id, id != ""
}

viewer_cmd :: proc(self, spec_path, state_dir, name: string) -> string {
	return fmt.tprintf("%s view %s %s/%s.json", self, spec_path, state_dir, name)
}

viewer_running :: proc(name: string) -> bool {
	code, _, _ := run({"pgrep", "-f", fmt.tprintf("(boardd view|viewer) .*/%s\\.json", name)})
	return code == 0
}

// ---- sources ----

Source :: struct {
	board, cmd, into, root: string,
	idx, timeout:           int,
	every, stale:           f64,
	stop:                   ^Stop,
}

send_err :: proc(s: ^Source, msg: Maybe(string)) {
	post(Msg{board = strings.clone(s.board), kind = .Err, idx = s.idx, msg = msg})
}

send_data :: proc(s: ^Source, text: string) {
	t := strings.trim_space(text)
	v, err := rt.parse_json(t)
	if err != nil {
		rt.destroy(v)
		v = json.String(strings.clone(t))
	}
	post(Msg{board = strings.clone(s.board), kind = .Data, into = strings.clone(s.into), value = v})
}

// Sleep `secs`, waking every 100 ms to check the stop flag. Returns false if stopped.
nap :: proc(stop: ^Stop, secs: f64) -> bool {
	until := time.tick_add(time.tick_now(), time.Duration(secs * f64(time.Second)))
	for time.tick_diff(time.tick_now(), until) > 0 {
		if stopped(stop) do return false
		time.sleep(100 * time.Millisecond)
	}
	return !stopped(stop)
}

// Give a source thread its own mmap-backed scratch arena. Unlike the default per-thread temp
// allocator (heap-backed), its memory goes back to the OS when the thread ends.
thread_scratch :: proc(a: ^virtual.Arena) -> mem.Allocator {
	_ = virtual.arena_init_growing(a, 256 * mem.Kilobyte)
	return virtual.arena_allocator(a)
}

free_source :: proc(s: ^Source) {
	delete(s.board)
	delete(s.cmd)
	delete(s.into)
	delete(s.root)
	free(s)
}

poll_source :: proc(s: ^Source) {
	defer free_source(s)
	scratch: virtual.Arena
	context.temp_allocator = thread_scratch(&scratch)
	defer virtual.arena_destroy(&scratch)
	for !stopped(s.stop) {
		code, out, errout := run({"timeout", "-k", "1", fmt.tprint(s.timeout), "sh", "-c", s.cmd}, s.root)
		if code == 0 {
			send_data(s, out)
			send_err(s, nil)
		} else {
			first, _, _ := strings.partition(errout, "\n")
			send_err(s, fmt.aprintf("rc=%d %s", code, first))
		}
		free_all(context.temp_allocator)
		if s.every <= 0 || !nap(s.stop, s.every) do break
	}
}

Line_Reader :: struct {
	f:    ^os.File,
	out:  chan.Chan(string),
	done: bool,
}

read_lines :: proc(r: ^Line_Reader) {
	buf: [4096]u8
	line := make([dynamic]u8)
	defer delete(line)
	for {
		n, err := os.read(r.f, buf[:])
		if n <= 0 || err != nil {
			if len(line) > 0 do chan.send(r.out, strings.clone(string(line[:]))) // last line without a newline
			break
		}
		for c in buf[:n] {
			if c == '\n' {
				chan.send(r.out, strings.clone(string(line[:])))
				clear(&line)
			} else {
				append(&line, c)
			}
		}
	}
	sync.atomic_store(&r.done, true)
}

// Long-running command: one JSON document per stdout line, applied the moment it arrives.
stream_source :: proc(s: ^Source) {
	defer free_source(s)
	scratch: virtual.Arena
	context.temp_allocator = thread_scratch(&scratch)
	defer virtual.arena_destroy(&scratch)
	restart_after := max(s.every, 1)
	for !stopped(s.stop) {
		r, w, perr := os.pipe()
		if perr != nil {
			send_err(s, fmt.aprint(perr))
			return
		}
		// setsid: own process group, so stopping kills the whole pipeline.
		p, err := os.process_start({command = {"setsid", "sh", "-c", s.cmd}, working_dir = s.root, stdout = w})
		os.close(w)
		if err != nil {
			os.close(r)
			send_err(s, fmt.aprint(err))
			return
		}
		lines, _ := chan.create_buffered(chan.Chan(string), 256, context.allocator)
		reader := new(Line_Reader)
		reader^ = {f = r, out = lines}
		rth := thread.create_and_start_with_poly_data(reader, read_lines)
		last_line := time.tick_now()
		why := "stream exited; restarting"
		loop: for {
			for {
				line, ok := chan.try_recv(lines)
				if !ok do break
				last_line = time.tick_now()
				send_data(s, line)
				delete(line)
			}
			if sync.atomic_load(&reader.done) && chan.len(lines) == 0 do break // command exited
			if stopped(s.stop) do break
			if s.stale > 0 && time.duration_seconds(time.tick_since(last_line)) > s.stale {
				why = fmt.tprintf("no output for %vs; restarting", s.stale)
				break loop
			}
			time.sleep(100 * time.Millisecond)
		}
		run({"kill", "-TERM", "--", fmt.tprintf("-%d", p.pid)})
		_, _ = os.process_wait(p)
		thread.join(rth)
		thread.destroy(rth)
		for line in chan.try_recv(lines) do delete(line)
		chan.destroy(lines)
		os.close(r)
		free(reader)
		if stopped(s.stop) do return
		send_err(s, strings.clone(why))
		free_all(context.temp_allocator)
		time.sleep(time.Duration(restart_after * f64(time.Second)))
	}
}

spawn_sources :: proc(name: string, def: Value, root: string, stop: ^Stop) {
	for s, idx in rt.array_of(def, "sources") {
		cmd, into := rt.str_of(s, "cmd"), rt.str_of(s, "into")
		if !rt.has(s, "cmd") || !rt.has(s, "into") {
			log("%s: source %d needs \"cmd\" and \"into\"", name, idx)
			continue
		}
		src := new(Source)
		src^ = {board = strings.clone(name), cmd = strings.clone(cmd), into = strings.clone(into), root = strings.clone(root), idx = idx, stop = stop}
		src.every, _ = rt.f64_of(s, "every")
		t, tok := rt.uint_of(s, "timeout")
		src.timeout = max(int(t), 1) if tok else 10
		src.stale, _ = rt.f64_of(s, "stale") // >0: restart the stream if it prints nothing for this many seconds
		if rt.is_true(s, "stream") {
			thread.create_and_start_with_poly_data(src, stream_source, self_cleanup = true)
		} else {
			thread.create_and_start_with_poly_data(src, poll_source, self_cleanup = true)
		}
	}
}

write_state :: proc(dir, name: string, state: Value) {
	path := fmt.tprintf("%s/%s.json", dir, name)
	tmp := fmt.tprintf("%s/%s.json.tmp", dir, name)
	if os.write_entire_file(tmp, rt.to_json(state, context.temp_allocator)) == nil {
		os.rename(tmp, path) // atomic: the viewer never sees a half-written file
	}
}

// Snapshot of herdr: workspaces, tabs, panes, and the pane layout of boardd's tab.
// Exposed to boards as state under "/herdr" (only when a board's spec mentions "/herdr"). Heap-owned.
herdr_state :: proc() -> Value {
	list :: proc(key: string, args: ..string) -> Value {
		r, ok := herdr(..args)
		if !ok do return make(json.Array)
		v, _ := rt.get(r, key)
		return rt.clone(v)
	}
	panes := list("panes", "pane", "list")
	lines := make(json.Array)
	for p in rt.as_array(panes) {
		or_dash :: proc(s: string, d: string) -> string { return s if s != "" else d }
		label := rt.str_of(p, "label")
		if !rt.has(p, "label") do label = rt.str_of(p, "terminal_title_stripped")
		line := fmt.aprintf("%s %-8s %-8s %s", or_dash(rt.str_of(p, "pane_id"), "?"), or_dash(rt.str_of(p, "agent"), "-"),
			or_dash(rt.str_of(p, "agent_status"), "?"), label)
		append(&lines, json.String(line))
	}
	layout: Value = json.Null(nil)
	if r, ok := herdr("pane", "layout"); ok {
		l, _ := rt.get(r, "layout")
		layout = rt.clone(l)
	}
	rows := make(json.Array)
	for p in rt.array_of(layout, "panes") {
		rect, _ := rt.get(p, "rect")
		n :: proc(r: Value, k: string) -> json.Value {
			x, _ := rt.get(r, k)
			i, _ := x.(json.Integer)
			return json.String(fmt.aprint(i))
		}
		id := rt.str_of(p, "pane_id")
		row := make(json.Array)
		append(&row, json.String(strings.clone(id if id != "" else "?")), n(rect, "x"), n(rect, "y"), n(rect, "width"), n(rect, "height"))
		append(&rows, row)
	}
	o := make(json.Object)
	o[strings.clone("layout_rows")] = rows
	o[strings.clone("workspaces")] = list("workspaces", "workspace", "list")
	o[strings.clone("tabs")] = list("tabs", "tab", "list")
	o[strings.clone("panes")] = panes
	o[strings.clone("layout")] = layout
	o[strings.clone("lines")] = lines
	return o
}

Errors :: map[string]map[int]string

error_list :: proc(e: map[int]string) -> Value {
	keys := slice.map_keys(e, context.temp_allocator) or_else nil
	slice.sort(keys)
	out := make(json.Array)
	for i in keys do append(&out, json.String(fmt.aprintf("source %d: %s", i, e[i])))
	return out
}

apply :: proc(m: Msg, boards: ^map[string]Board, errors: ^Errors, pending: ^map[string]bool) {
	defer delete(m.board)
	switch m.kind {
	case .Data:
		defer delete(m.into)
		b, ok := &boards[m.board]
		if !ok {
			rt.destroy(m.value)
			return
		}
		before, found := rt.pointer(b.state, m.into)
		if found && m.into != "" && m.into != "/" && rt.equal(before, m.value) {
			rt.destroy(m.value)
		} else {
			rt.set_ptr(&b.state, m.into, m.value)
			if m.board not_in pending do pending[strings.clone(m.board)] = true
		}
		if m.into != "/boardd" && m.into != "/herdr" do b.last_data = time.tick_now()
	case .Err:
		if m.board not_in errors do errors[strings.clone(m.board)] = make(map[int]string)
		e := &errors[m.board]
		changed := false
		if msg, has := m.msg.?; has {
			old, had := e[m.idx]
			changed = !had || old != msg
			if had do delete(old)
			e[m.idx] = msg
		} else if old, had := e[m.idx]; had {
			delete(old)
			delete_key(e, m.idx)
			changed = true
		}
		if !changed do return
		b, ok := &boards[m.board]
		if !ok do return
		list := error_list(e^)
		rt.set_ptr(&b.state, "/_errors", list)
		if m.board not_in pending do pending[strings.clone(m.board)] = true
		strs := make([dynamic]string, context.temp_allocator)
		for x in rt.as_array(list) do append(&strs, rt.as_str(x) or_else "")
		log("%s: %s", m.board, "sources ok" if len(strs) == 0 else strings.join(strs[:], "; ", context.temp_allocator))
	}
}

clock_now :: proc() -> string {
	_, out, _ := run({"date", "+%H:%M:%S"})
	return strings.trim_space(out)
}

// `boardd --check [dir...]`: validate every board file (JSON, "spec" present, spec passes the catalog). Exit 1 on any error.
check_boards :: proc(dirs: []string) -> ! {
	n, bad := 0, 0
	for dir in dirs {
		entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		slice.sort_by(entries, proc(a, b: os.File_Info) -> bool { return a.name < b.name })
		for e in entries {
			if filepath.ext(e.name) != ".json" do continue
			n += 1
			msg := ""
			data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
			if rerr != nil {
				msg = fmt.tprint(rerr)
			} else if v, err := rt.parse_json(string(data), context.temp_allocator); err != nil {
				msg = fmt.tprint(err)
			} else if s, has := rt.get(v, "spec"); !has {
				msg = "missing \"spec\""
			} else {
				msg = rt.validate_spec(s)
			}
			if msg == "" {
				fmt.println("ok  ", e.fullpath)
			} else {
				bad += 1
				fmt.printfln("FAIL %s: %s", e.fullpath, msg)
			}
		}
	}
	fmt.printfln("%d boards, %d failed", n, bad)
	os.exit(1 if bad > 0 else 0)
}

same_placement :: proc(b: ^Board, direction: string, ratio: Maybe(f64), parent, tab, workspace: Maybe(string)) -> bool {
	return b.direction == direction && b.ratio == ratio && b.parent == parent && b.tab == tab && b.workspace == workspace
}

// Only an explicit false counts (like "enabled": false); a missing or non-bool value does not.
is_false :: proc(v: Value, key: string) -> bool {
	x, _ := rt.get(v, key)
	b, ok := rt.as_bool(x)
	return ok && !b
}

maybe_str :: proc(v: Value, key: string) -> Maybe(string) {
	x, _ := rt.get(v, key)
	s, ok := rt.as_str(x)
	if !ok do return nil
	return strings.clone(s)
}

free_board :: proc(b: ^Board) {
	rt.destroy(b.state)
	delete(b.path)
	delete(b.direction)
	if s, ok := b.parent.?; ok do delete(s)
	if s, ok := b.tab.?; ok do delete(s)
	if s, ok := b.workspace.?; ok do delete(s)
	if s, ok := b.pane.?; ok do delete(s)
}

set_pane :: proc(b: ^Board, id: Maybe(string)) {
	if s, ok := b.pane.?; ok do delete(s)
	b.pane = nil
	if s, ok := id.?; ok do b.pane = strings.clone(s)
}

// `boardd view <spec-or-board.json> [state.json]`: draw one board full-screen at 60 fps. Spec and
// state files hot-reload when they change. q or Esc quits. Scrollable widgets: Tab focus,
// j/k/arrows, PgUp/PgDn, g/G. boardd runs this in each board pane.
view :: proc(args: []string) -> ! {
	if len(args) < 1 {
		fmt.eprintln("usage: boardd view <spec-or-board.json> [state.json]")
		os.exit(2)
	}
	spec := rt.spec_load(strings.clone_to_cstring(args[0]))
	if spec == nil {
		fmt.eprintln(rt.last_error())
		os.exit(1)
	}
	if len(args) > 1 do rt.state_watch(strings.clone_to_cstring(args[1]))
	t := rt.init()
	clock := rt.clock_make(60)
	loop: for {
		rt.draw(t, spec)
		for k := rt.frame_wait(&clock); k != i32(rt.Key.None); k = rt.poll_key(0) {
			if k == 'q' || k == i32(rt.Key.Esc) do break loop
			rt.ui_key(k)
		}
	}
	rt.restore(t)
	os.exit(0)
}

main :: proc() {
	// Source threads come and go on every reload, and each holds multi-MB arena blocks (core:os
	// temp arenas). By default glibc gives each thread its own malloc arena and, after the first
	// big free, serves big blocks from the heap and keeps them: RSS climbs by tens of MB. A fixed
	// mmap threshold returns big blocks to the OS on free; one arena is plenty for this load.
	mallopt(M_MMAP_THRESHOLD, 128 * 1024)
	mallopt(M_ARENA_MAX, 1)
	args := os.args
	if len(args) > 1 && args[1] == "view" do view(args[2:])
	home := os.get_env("HOME", context.allocator)
	exe_dir, _ := os.get_executable_directory(context.allocator) // <root>/boardd
	default_root := filepath.dir(exe_dir)
	if len(args) > 1 && args[1] == "--check" {
		dirs := args[2:]
		if len(dirs) == 0 do dirs = {fmt.aprintf("%s/boards", default_root), fmt.aprintf("%s/.config/boardkit/boards", home)}
		check_boards(dirs)
	}
	root := args[1] if len(args) > 1 else default_root
	// Board dirs: <root>/boards, then extra args, then $BOARDD_DIRS (colon-separated) if set, else ~/.config/boardkit/boards.
	// Earlier dirs win on name clashes.
	dirs := make([dynamic]string)
	append(&dirs, fmt.aprintf("%s/boards", root))
	if len(args) > 2 do append(&dirs, ..args[2:])
	if extra, found := os.lookup_env("BOARDD_DIRS", context.allocator); found {
		for d in strings.split(extra, ":") do if d != "" do append(&dirs, d)
	} else {
		append(&dirs, fmt.aprintf("%s/.config/boardkit/boards", home))
	}
	state_dir := fmt.aprintf("%s/.cache/boardkit", home)
	os.make_directory_all(state_dir)
	os.make_directory_all(dirs[0])
	self_pane, has_self := os.lookup_env("HERDR_PANE_ID", context.allocator)
	viewer, _ := os.get_executable_path(context.allocator) // panes run `boardd view`
	log("watching %v (state in %s)", dirs[:], state_dir)

	msgs, _ = chan.create_buffered(chan.Chan(Msg), 4096, context.allocator)
	boards := make(map[string]Board)
	errors := make(Errors)
	pending := make(map[string]bool)
	last_scan := time.tick_add(time.tick_now(), -time.Second)
	last_flush := time.tick_now()
	herdr_snapshot: Value
	path_of := make(map[string]string)

	for {
		// Slow work (directory scan, herdr calls) runs on a 500 ms tick. Data never waits for it.
		if time.tick_since(last_scan) >= 500 * time.Millisecond {
			last_scan = time.tick_now()
			on_disk := make(map[string]time.Time, context.temp_allocator)
			for _, p in path_of do delete(p)
			clear(&path_of)
			for dir in dirs {
				entries, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
				for e in entries {
					if filepath.ext(e.name) != ".json" do continue
					stem := filepath.stem(e.name)
					if stem in on_disk do continue
					on_disk[stem] = e.modification_time
					path_of[strings.clone(stem)] = strings.clone(e.fullpath)
				}
			}

			// removed boards
			gone := make([dynamic]string, context.temp_allocator)
			for n in boards do if n not_in on_disk do append(&gone, n)
			for n in gone {
				key, b := delete_key(&boards, n)
				sync.atomic_store(&b.stop.flag, true)
				if p, ok := b.pane.?; ok do herdr("pane", "close", p)
				os.remove(fmt.tprintf("%s/%s.json", state_dir, n))
				log("%s: removed", n)
				free_board(&b)
				delete(key)
			}

			// new or edited boards
			for name, mtime in on_disk {
				if b, ok := boards[name]; ok && b.mtime == mtime && b.path == path_of[name] do continue
				data, rerr := os.read_entire_file(path_of[name], context.temp_allocator)
				def: Value
				perr := ""
				if rerr != nil {
					perr = fmt.tprint(rerr)
				} else if v, err := rt.parse_json(string(data), context.temp_allocator); err != nil {
					perr = fmt.tprint(err)
				} else if !rt.has(v, "spec") {
					perr = "missing \"spec\""
				} else {
					def = v
				}
				if perr != "" {
					log("%s: %s (keeping previous version)", name, perr)
					if b, ok := &boards[name]; ok do b.mtime = mtime // don't re-log every tick
					continue
				}
				had_old := name in boards
				old_key, old := delete_key(&boards, name)
				if had_old do sync.atomic_store(&old.stop.flag, true)
				stop := new(Stop)
				if name in errors {
					ek, ev := delete_key(&errors, name)
					for _, m in ev do delete(m)
					delete(ev)
					delete(ek)
				}
				spawn_sources(name, def, root, stop)
				h, _ := rt.get(def, "herdr") // placement: {"tab", "workspace", "parent": "self|<pane id>|board:<name>", "direction", "ratio"}
				direction := rt.str_of(h, "direction")
				if direction == "" do direction = rt.str_of(def, "direction")
				if direction == "" do direction = "right"
				ratio: Maybe(f64)
				if r, ok := rt.f64_of(h, "ratio"); ok do ratio = r
				parent, tab, workspace := maybe_str(h, "parent"), maybe_str(h, "tab"), maybe_str(h, "workspace")
				pane: Maybe(string)
				moved := had_old && old.path != path_of[name]
				if had_old {
					if same_placement(&old, direction, ratio, parent, tab, workspace) && !moved {
						pane = old.pane // same placement: keep the pane (the viewer hot-reloads the spec itself)
					} else if p, ok := old.pane.?; ok {
						// the viewer holds a path, so a moved file needs a new one; same for a new place
						herdr("pane", "close", p)
						log("%s: %s, reopening pane", name, "board file moved" if moved else "placement changed")
					}
				} else if p, ok := board_panes()[name]; ok {
					pane = p // adopt a pane from a previous boardd run
				}
				state: Value = make(json.Object)
				if had_old {
					state, old.state = old.state, nil
					rt.set_ptr(&state, "/_errors", make(json.Array)) // errors were reset above, so drop their stale copy in state too
				}
				spec, _ := rt.get(def, "spec")
				spec_text := rt.to_json(spec, context.temp_allocator)
				nb := Board{
					mtime        = mtime,
					path         = strings.clone(path_of[name]),
					stop         = stop,
					state        = state,
					direction    = strings.clone(direction),
					ratio        = ratio,
					parent       = parent,
					tab          = tab,
					workspace    = workspace,
					wants_herdr  = strings.contains(spec_text, "/herdr"),
					wants_boardd = strings.contains(spec_text, "/boardd"),
					last_data    = time.tick_now(),
					enabled      = !is_false(def, "enabled"),
					verify_pane  = !had_old && pane != nil,
					ready_at     = time.tick_add(time.tick_now(), 1200 * time.Millisecond), // let sources produce a first state
				}
				set_pane(&nb, pane)
				if had_old {
					free_board(&old)
					delete(old_key)
				}
				boards[strings.clone(name)] = nb
				if name not_in pending do pending[strings.clone(name)] = true
				log("%s: %s", name, "reloaded" if had_old else "added")
			}

			// herdr snapshot for boards that display it
			any_herdr, any_boardd := false, false
			for _, b in boards {
				any_herdr ||= b.wants_herdr
				any_boardd ||= b.wants_boardd
			}
			if any_herdr {
				snap := herdr_state()
				if rt.equal(snap, herdr_snapshot) {
					rt.destroy(snap)
				} else {
					rt.destroy(herdr_snapshot)
					herdr_snapshot = snap
					for n, &b in boards do if b.wants_herdr {
						rt.set_ptr(&b.state, "/herdr", rt.clone(herdr_snapshot))
						if n not_in pending do pending[strings.clone(n)] = true
					}
				}
			}

			// boardd's own status, for boards that display it: state under "/boardd"
			if any_boardd {
				names := slice.map_keys(boards, context.temp_allocator) or_else nil
				slice.sort(names)
				rows := make(json.Array)
				bad := 0
				for n in names {
					b := boards[n]
					e := errors[n] or_else nil
					status := "off" if !b.enabled else "closed" if b.dismissed else "ERROR" if len(e) > 0 else "ok"
					if status == "ERROR" do bad += 1
					age := int(time.duration_seconds(time.tick_since(b.last_data)))
					age_s := fmt.tprintf("%ds", age) if age < 120 else fmt.tprintf("%dm", age / 60)
					msgs_l := make([dynamic]string, context.temp_allocator)
					keys := slice.map_keys(e, context.temp_allocator) or_else nil
					slice.sort(keys)
					for k in keys do append(&msgs_l, e[k])
					cells := make(json.Array)
					for c in ([]string{n, status, b.pane.? or_else "-", b.tab.? or_else "-", age_s, strings.join(msgs_l[:], "; ", context.temp_allocator)}) {
						append(&cells, json.String(strings.clone(c)))
					}
					row := make(json.Object)
					row[strings.clone("cells")] = cells
					row[strings.clone("fg")] = json.String(strings.clone("red" if status == "ERROR" else "green" if status == "ok" else "yellow"))
					append(&rows, row)
				}
				snap := make(json.Object)
				snap[strings.clone("rows")] = rows
				snap[strings.clone("summary")] = json.String(fmt.aprintf("%d boards | %d with errors | %s", len(boards), bad, clock_now()))
				for n, &b in boards do if b.wants_boardd {
					rt.set_ptr(&b.state, "/boardd", rt.clone(snap))
					if n not_in pending do pending[strings.clone(n)] = true
				}
				rt.destroy(snap)
			}

			// panes
			live := board_panes()
			wanted := make(map[string]bool, context.temp_allocator)
			for n, b in boards do if b.enabled && !b.dismissed do wanted[n] = true
			for name, &b in boards {
				if !b.enabled {
					if p, ok := b.pane.?; ok {
						herdr("pane", "close", p)
						log("%s: disabled, pane closed", name)
						set_pane(&b, nil)
					}
					continue
				}
				if b.verify_pane {
					b.verify_pane = false
					if p, ok := b.pane.?; ok && !viewer_running(name) {
						herdr("pane", "run", p, viewer_cmd(viewer, path_of[name], state_dir, name))
						log("%s: adopted pane %s had no viewer running; relaunched", name, p)
					}
				}
				if p, ok := b.pane.?; ok && (live[name] or_else "") != p {
					log("%s: pane closed by hand; edit %s.json to reopen", name, name)
					set_pane(&b, nil)
					b.dismissed = true
				}
				if b.pane != nil || b.dismissed || time.tick_diff(time.tick_now(), b.ready_at) > 0 do continue
				if !os.exists(fmt.tprintf("%s/%s.json", state_dir, name)) do write_state(state_dir, name, b.state)
				parent: Maybe(string)
				explicit := false // an explicit "parent" other than "self" wins over "tab" and splits that pane
				bp, has_parent := b.parent.?
				if !has_parent || bp == "self" {
					if has_self do parent = self_pane
				} else if strings.has_prefix(bp, "board:") {
					explicit = true
					pn := bp[len("board:"):]
					if id, ok := live[pn]; ok {
						parent = id
					} else if pn in wanted {
						continue // parent board is coming up; try next tick
					} else {
						log("%s: parent board \"%s\" does not exist; edit %s.json", name, pn, name)
						b.dismissed = true
						continue
					}
				} else {
					explicit = true
					parent = bp
				}
				placed: string
				ok: bool
				if tab, has_tab := b.tab.?; has_tab && !explicit {
					placed, ok = place_in_tab(b.workspace, tab, b.direction, b.ratio, root)
				} else {
					placed, ok = split_pane(parent, b.direction, b.ratio, root)
				}
				if ok {
					herdr("pane", "rename", placed, fmt.tprintf("board:%s", name))
					herdr("pane", "run", placed, viewer_cmd(viewer, path_of[name], state_dir, name))
					log("%s: pane %s opened", name, placed)
					live[name] = placed
					set_pane(&b, placed)
				} else {
					log("%s: could not create pane (is herdr running? bad parent?)", name)
					b.dismissed = true
				}
			}
		}

		// Sleep until a source posts data, the next scan is due, or (with writes pending) the next flush.
		wait := 500 * time.Millisecond - time.tick_since(last_scan)
		if len(pending) > 0 do wait = min(wait, 16 * time.Millisecond - time.tick_since(last_flush))
		if wait > 0 do sync.sema_wait_with_timeout(&wake, wait)
		for {
			m, ok := chan.try_recv(msgs)
			if !ok do break
			apply(m, &boards, &errors, &pending)
		}
		// Coalesce: at most one state-file write per board per 16 ms, however fast data arrives.
		if len(pending) > 0 && time.tick_since(last_flush) >= 16 * time.Millisecond {
			for n in pending {
				if b, ok := boards[n]; ok do write_state(state_dir, n, b.state)
				delete(n)
			}
			clear(&pending)
			last_flush = time.tick_now()
		}
		free_all(context.temp_allocator)
	}
}
