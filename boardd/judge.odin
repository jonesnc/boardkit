package main

// Judge threads: one per source with a "judge" block (see ratatui/judge.odin for the format).
// The source thread offers each new output; the judge thread answers the latest one at most every
// `every` seconds (default 2), so a slow or failing Jev call never holds up a source or a frame.
// With a TypeSafe key it asks Jev; without one, or when Jev fails, it uses the questions' rules.
// Key: $TYPESAFE_API_KEY, else the first line of ~/.config/boardkit/typesafe.key.
// Endpoint: $TYPESAFE_URL, else https://api.typesafe.ai/v1/systemone.

import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import rt "../ratatui"

JEV_URL :: "https://api.typesafe.ai/v1/systemone"
JUDGE_IDX :: 1000 // judge errors use source index + JUDGE_IDX, so they sit beside the source's own

Judge :: struct {
	board, into, of: string,
	def:             Value, // the judge block (heap clone)
	idx, timeout:    int,
	every:           f64,
	stop:            ^Stop,
	refs:            int, // the source thread and the judge thread; the last to let go frees it
	mu:              sync.Mutex,
	input:           string, // latest offered output as JSON text; "" = nothing new
	ready:           sync.Sema,
}

judge_start :: proc(board: string, jd: Value, idx: int, stop: ^Stop) -> ^Judge {
	j := new(Judge)
	j^ = {board = strings.clone(board), into = strings.clone(rt.str_of(jd, "into")), of = strings.clone(rt.str_of(jd, "of")),
		def = rt.clone(jd), idx = idx, stop = stop, refs = 2, every = 2, timeout = 10}
	if e, ok := rt.f64_of(jd, "every"); ok do j.every = e
	if t, ok := rt.uint_of(jd, "timeout"); ok do j.timeout = max(int(t), 1)
	thread.create_and_start_with_poly_data(j, judge_loop, self_cleanup = true)
	return j
}

judge_release :: proc(j: ^Judge) {
	if sync.atomic_sub(&j.refs, 1) != 1 do return
	delete(j.board)
	delete(j.into)
	delete(j.of)
	delete(j.input)
	rt.destroy(j.def)
	free(j)
}

// Called from the source thread with its freshly parsed output. The source posts its data before
// judge_wake, so the judge's answers always land after it: an "into": "/" source replaces the whole
// state, answers included.
judge_offer :: proc(j: ^Judge, v: Value) {
	sel, found := rt.pointer(v, j.of)
	if !found do return
	text := rt.to_json(sel)
	sync.mutex_lock(&j.mu)
	delete(j.input)
	j.input = text
	sync.mutex_unlock(&j.mu)
}

judge_wake :: proc(j: ^Judge) {
	sync.sema_post(&j.ready)
}

judge_loop :: proc(j: ^Judge) {
	defer judge_release(j)
	scratch: virtual.Arena
	context.temp_allocator = thread_scratch(&scratch)
	defer virtual.arena_destroy(&scratch)
	last := ""
	defer delete(last)
	kept: Value // the last answers; sent again for unchanged text, which costs no Jev call
	defer rt.destroy(kept)
	for !stopped(j.stop) {
		if !sync.sema_wait_with_timeout(&j.ready, 100 * time.Millisecond) do continue
		sync.mutex_lock(&j.mu)
		text := j.input
		j.input = ""
		sync.mutex_unlock(&j.mu)
		if text == "" do continue
		if text == last {
			delete(text)
			if kept != nil do post(Msg{board = strings.clone(j.board), kind = .Data, into = strings.clone(j.into), value = rt.clone(kept)})
			continue
		}
		delete(last)
		last = text
		state, _ := rt.parse_json(text, context.temp_allocator)
		jev, err := ask_jev(j, state)
		answers := rt.judge_answers(j.def, state, jev)
		rt.destroy(kept)
		kept = rt.clone(answers)
		post(Msg{board = strings.clone(j.board), kind = .Data, into = strings.clone(j.into), value = answers})
		post(Msg{board = strings.clone(j.board), kind = .Err, idx = j.idx + JUDGE_IDX, msg = err})
		free_all(context.temp_allocator)
		if j.every > 0 && !nap(j.stop, j.every) do break
	}
}

typesafe_key :: proc() -> string {
	if k, ok := os.lookup_env("TYPESAFE_API_KEY", context.temp_allocator); ok && strings.trim_space(k) != "" {
		return strings.trim_space(k)
	}
	home := os.get_env("HOME", context.temp_allocator)
	data, err := os.read_entire_file(fmt.tprintf("%s/.config/boardkit/typesafe.key", home), context.temp_allocator)
	if err != nil do return ""
	first, _, _ := strings.partition(string(data), "\n")
	return strings.trim_space(first)
}

// Jev's parsed response (temp memory), or nil. No key: nil and no error, so rules answer quietly.
// err is heap-owned, for the banner.
ask_jev :: proc(j: ^Judge, state: Value) -> (resp: Maybe(Value), err: Maybe(string)) {
	key := typesafe_key()
	if key == "" do return nil, nil
	body, terr := os.create_temp_file("", "boardd-jev-*")
	if terr != nil do return nil, fmt.aprint("jev:", terr)
	path := strings.clone(os.name(body), context.temp_allocator)
	defer os.remove(path)
	os.write_string(body, rt.judge_request(j.def, state))
	os.close(body)
	url := os.get_env("TYPESAFE_URL", context.temp_allocator)
	if url == "" do url = JEV_URL
	env, _ := os.environ(context.temp_allocator)
	extra := []string{fmt.tprintf("TYPESAFE_API_KEY=%s", key), fmt.tprintf("BODY=%s", path), fmt.tprintf("URL=%s", url), fmt.tprintf("T=%d", j.timeout)}
	full := make([dynamic]string, context.temp_allocator)
	append(&full, ..env)
	append(&full, ..extra)
	// The key goes through the environment and stdin, never argv, so `ps` does not show it.
	code, out, errout := run({"sh", "-c", `printf 'Authorization: Bearer %s\n' "$TYPESAFE_API_KEY" | ` +
		`curl -sS --max-time "$T" -H @- -H 'Content-Type: application/json' --data-binary @"$BODY" -w '\n%{http_code}' "$URL"`}, env = full[:])
	if code != 0 {
		first, _, _ := strings.partition(errout, "\n")
		return nil, fmt.aprintf("jev: curl rc=%d %s (using rules)", code, first)
	}
	cut := strings.last_index_byte(out, '\n')
	if cut < 0 do return nil, strings.clone("jev: empty response (using rules)")
	payload, status := out[:cut], strings.trim_space(out[cut + 1:])
	if status != "200" do return nil, fmt.aprintf("jev: http %s %.80s (using rules)", status, strings.trim_space(payload))
	v, perr := rt.parse_json(payload, context.temp_allocator)
	if perr != nil do return nil, fmt.aprint("jev: bad response:", perr, "(using rules)")
	return v, nil
}
