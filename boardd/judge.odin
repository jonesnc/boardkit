package main

// Judge threads: one per source with a "judge" block (see ratatui/judge.odin for the format).
// The source thread offers each new output; the judge thread answers the latest one at most every
// `every` seconds (default 2), so a slow or failing Jev call never holds up a source or a frame.
// With a TypeSafe key it asks Jev; without one, or when Jev fails, it uses the questions' rules.
// Key: $TYPESAFE_API_KEY, else the first line of ~/.config/boardkit/typesafe.key.
// Endpoint: $TYPESAFE_URL, else https://api.typesafe.ai/v1/systemone.

import "core:encoding/json"
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
ROWS_PER_ASK :: 16 // rows in one Jev request; each row adds one question per judge question

Judge :: struct {
	board, into, of: string,
	each:            string, // "" = judge "of" once; else judge each item of this array
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
		each = strings.clone(rt.str_of(jd, "each")),
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
	delete(j.each)
	delete(j.input)
	rt.destroy(j.def)
	free(j)
}

// Called from the source thread with its freshly parsed output. The source posts its data before
// judge_wake, so the judge's answers always land after it: an "into": "/" source replaces the whole
// state, answers included.
judge_offer :: proc(j: ^Judge, v: Value) {
	sel, found := rt.pointer(v, j.each if j.each != "" else j.of)
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
	if j.each != "" {
		judge_rows_loop(j)
		return
	}
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
		jev, err := ask_jev(j, rt.judge_request(j.def, state))
		answers := rt.judge_answers(j.def, state, jev)
		rt.destroy(kept)
		kept = rt.clone(answers)
		post(Msg{board = strings.clone(j.board), kind = .Data, into = strings.clone(j.into), value = answers})
		post(Msg{board = strings.clone(j.board), kind = .Err, idx = j.idx + JUDGE_IDX, msg = err})
		free_all(context.temp_allocator)
		if j.every > 0 && !nap(j.stop, j.every) do break
	}
}

// Per-row mode: answers are cached by each row's text, so Jev is asked only about new or changed
// rows. Every offer posts all answers again, because the source's data replaces the rows ("set"
// writes included) each time it runs.
judge_rows_loop :: proc(j: ^Judge) {
	defer judge_release(j)
	scratch: virtual.Arena
	context.temp_allocator = thread_scratch(&scratch)
	defer virtual.arena_destroy(&scratch)
	cache: map[string]Value // row text -> its answers
	defer {
		for k, v in cache {
			delete(k)
			rt.destroy(v)
		}
		delete(cache)
	}
	for !stopped(j.stop) {
		if !sync.sema_wait_with_timeout(&j.ready, 100 * time.Millisecond) do continue
		sync.mutex_lock(&j.mu)
		text := j.input
		j.input = ""
		sync.mutex_unlock(&j.mu)
		if text == "" do continue
		state, _ := rt.parse_json(text, context.temp_allocator)
		delete(text)
		rows := rt.as_array(state)
		items := make([]Value, len(rows), context.temp_allocator)
		keys := make([]string, len(rows), context.temp_allocator)
		missing := make([dynamic]int, context.temp_allocator)
		retry := make([dynamic]string, context.temp_allocator)
		for row, i in rows {
			items[i], _ = rt.pointer(row, j.of)
			keys[i] = rt.to_json(items[i], context.temp_allocator)
			if keys[i] in cache do continue
			dup := false
			for m in missing do if keys[m] == keys[i] do dup = true
			if !dup do append(&missing, i)
		}
		asked := false
		err: Maybe(string)
		for start := 0; start < len(missing); start += ROWS_PER_ASK {
			ids := missing[start:min(start + ROWS_PER_ASK, len(missing))]
			batch := make([]Value, len(ids), context.temp_allocator)
			for id, n in ids do batch[n] = items[id]
			jev: Maybe(Value)
			if err == nil {
				jev, err = ask_jev(j, rt.judge_rows_request(j.def, batch, ids))
				asked = asked || typesafe_key() != ""
			}
			for id in ids {
				cache[strings.clone(keys[id])] = rt.judge_row_answers(j.def, items[id], jev, id)
				if err != nil do append(&retry, keys[id])
			}
		}
		// Forget rows that are gone, and rule answers given only because Jev failed (asked again next time).
		gone := make([dynamic]string, context.temp_allocator)
		for k in cache {
			live := false
			for key in keys do if key == k do live = true
			if !live do append(&gone, k)
		}
		all := make(json.Array, 0, len(rows))
		for key, i in keys {
			ans := cache[key]
			append(&all, rt.clone(ans))
			for set in rt.judge_row_sets(j.def, ans, context.temp_allocator) {
				post(Msg{board = strings.clone(j.board), kind = .Data, into = fmt.aprintf("%s/%d%s", j.each, i, set.path), value = rt.clone(set.value)})
			}
		}
		post(Msg{board = strings.clone(j.board), kind = .Data, into = strings.clone(j.into), value = all})
		if asked || err != nil do post(Msg{board = strings.clone(j.board), kind = .Err, idx = j.idx + JUDGE_IDX, msg = err})
		append(&gone, ..retry[:])
		for k in gone {
			old_k, old_v := delete_key(&cache, k)
			delete(old_k)
			rt.destroy(old_v)
		}
		free_all(context.temp_allocator)
		if asked && j.every > 0 && !nap(j.stop, j.every) do break
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
ask_jev :: proc(j: ^Judge, request: string) -> (resp: Maybe(Value), err: Maybe(string)) {
	key := typesafe_key()
	if key == "" do return nil, nil
	body, terr := os.create_temp_file("", "boardd-jev-*")
	if terr != nil do return nil, fmt.aprint("jev:", terr)
	path := strings.clone(os.name(body), context.temp_allocator)
	defer os.remove(path)
	os.write_string(body, request)
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
