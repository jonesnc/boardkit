package ratatui

// Streaming: feed partial JSON chunks, re-render on every chunk that parses.

import "core:strings"

// Close open strings/brackets so a prefix parses. ok=false if it still cannot.
close_prefix :: proc(p: string, allocator := context.temp_allocator) -> (Value, bool) {
	stack := make([dynamic]u8, context.temp_allocator)
	in_str, esc := false, false
	for i in 0 ..< len(p) {
		c := p[i]
		if in_str {
			switch {
			case esc:       esc = false
			case c == '\\': esc = true
			case c == '"':  in_str = false
			}
		} else {
			switch c {
			case '"': in_str = true
			case '{': append(&stack, '}')
			case '[': append(&stack, ']')
			case '}', ']': if len(stack) > 0 do pop(&stack)
			}
		}
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, p)
	if in_str {
		if esc do strings.pop_byte(&b)
		strings.write_byte(&b, '"')
	}
	out := strings.trim_right_space(strings.to_string(b))
	resize(&b.buf, len(out))
	if len(out) > 0 {
		switch out[len(out) - 1] {
		case ':': strings.write_string(&b, "null")
		case ',': strings.pop_byte(&b)
		}
	}
	#reverse for c in stack do strings.write_byte(&b, c)
	v, err := parse_json(strings.to_string(b), allocator)
	if err != nil {
		destroy(v, allocator)
		return nil, false
	}
	return v, true
}

// Best-effort parse of a partial JSON document; falls back to earlier cut points.
parse_partial :: proc(s: string, allocator := context.temp_allocator) -> (Value, bool) {
	if v, ok := close_prefix(s, allocator); ok do return v, true
	cuts := make([dynamic]int, context.temp_allocator)
	in_str, esc := false, false
	for i in 0 ..< len(s) {
		c := s[i]
		if in_str {
			switch {
			case esc:       esc = false
			case c == '\\': esc = true
			case c == '"':  in_str = false
			}
		} else {
			switch c {
			case '"':      in_str = true
			case ',':      append(&cuts, i)
			case '{', '[': append(&cuts, i + 1)
			}
		}
	}
	#reverse for i in cuts {
		if v, ok := close_prefix(s[:i], allocator); ok do return v, true
	}
	return nil, false
}

Stream_State :: struct {
	buf:  [dynamic]u8,
	last: Value,
}

Stream :: ^Stream_State

stream_new :: proc() -> Stream {
	return new(Stream_State)
}

stream_free :: proc(s: Stream) {
	if s == nil do return
	delete(s.buf)
	destroy(s.last)
	free(s)
}

// Clear the buffer to start a new spec.
stream_reset :: proc(s: Stream) {
	if s == nil do return
	clear(&s.buf)
	destroy(s.last)
	s.last = nil
}

// Append a chunk and redraw. Returns 0 if drawn, 1 if nothing parseable yet
// (last good frame stays on screen), -1 on bad args, -3 on IO error.
stream_push :: proc(t: Term, s: Stream, chunk: cstring) -> i32 {
	if t == nil || s == nil || chunk == nil do return -1
	context.temp_allocator = scratch()
	defer free_all(context.temp_allocator)
	// Bytes: a chunk may end mid-UTF-8-character. Skip any prose/fence before the first '{'.
	append(&s.buf, ..transmute([]u8)string(chunk))
	text := strings.to_valid_utf8(string(s.buf[:]), "�", context.temp_allocator)
	start := strings.index_byte(text, '{')
	if start < 0 do return 1
	v, ok := parse_partial(text[start:], context.allocator)
	if !ok do return 1
	if _, is_obj := v.(Object); !is_obj {
		destroy(v)
		return 1
	}
	last_key = {}
	rc := draw_value(t, v, "")
	destroy(s.last)
	s.last = v
	return rc
}
