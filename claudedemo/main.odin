package main

import "core:fmt"
import "core:os"
import "core:strings"
import rt "../ratatui"

foreign import libc "system:c"

@(default_calling_convention = "c")
foreign libc {
	popen  :: proc(cmd: cstring, mode: cstring) -> rawptr ---
	pclose :: proc(f: rawptr) -> i32 ---
	fileno :: proc(f: rawptr) -> i32 ---
	read   :: proc(fd: i32, buf: rawptr, n: uint) -> int ---
}

EXTRA :: "\nNo markdown fences, no prose. Use hstack/vstack with sizes so the UI fills the screen; put a popup last only if asked."

// Streams the model's text: Anthropic SSE -> raw text deltas.
PIPELINE :: `jq -n --rawfile sys claudedemo/.system.txt --arg p "$UI_PROMPT" '{model:"claude-sonnet-5",max_tokens:4000,stream:true,system:$sys,messages:[{role:"user",content:$p}]}' | curl -sN https://api.anthropic.com/v1/messages -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d @- | grep --line-buffered '^data: ' | sed -u 's/^data: //' | jq -j --unbuffered 'select(.type=="content_block_delta") | .delta.text // empty'`

main :: proc() {
	if os.get_env("ANTHROPIC_API_KEY", context.temp_allocator) == "" {
		fmt.eprintln("set ANTHROPIC_API_KEY first")
		os.exit(1)
	}
	prompt := "a system dashboard: cpu gauge, memory gauge, a table of 4 processes, and a sparkline"
	if len(os.args) > 1 do prompt = strings.join(os.args[1:], " ", context.temp_allocator)

	sys := strings.concatenate({string(rt.catalog_prompt()), EXTRA}, context.temp_allocator)
	_ = os.write_entire_file("claudedemo/.system.txt", transmute([]u8)sys)
	os.set_env("UI_PROMPT", prompt)

	f := popen(PIPELINE, "r")
	if f == nil {
		fmt.eprintln("popen failed")
		os.exit(1)
	}
	t := rt.init()
	s := rt.stream_new()
	buf: [256]u8
	for {
		n := read(fileno(f), &buf[0], 255)
		if n <= 0 do break
		buf[n] = 0
		rt.stream_push(t, s, cstring(&buf[0]))
	}
	pclose(f)
	for { // done streaming; wait for quit
		k := rt.poll_key(100)
		if k == 'q' || k == i32(rt.Key.Esc) do break
	}
	rt.stream_free(s)
	rt.restore(t)
}
