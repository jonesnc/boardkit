package main

// Generic viewer: odin-viewer <spec.json> [state.json]
// Draws the spec at 60 fps. Spec and state files hot-reload when they change. q or Esc quits.
// Scrollable widgets: Tab focus, j/k/arrows, PgUp/PgDn, g/G.

import "core:fmt"
import "core:os"
import "core:strings"
import rt "../ratatui"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: viewer <spec.json> [state.json]")
		os.exit(2)
	}
	spec := rt.spec_load(strings.clone_to_cstring(os.args[1], context.temp_allocator))
	if spec == nil {
		fmt.eprintln(rt.last_error())
		os.exit(1)
	}
	if len(os.args) > 2 {
		rt.state_watch(strings.clone_to_cstring(os.args[2], context.temp_allocator))
	}
	t := rt.init()
	defer rt.restore(t)
	clock := rt.clock_make(60)
	for {
		rt.draw(t, spec)
		for k := rt.frame_wait(&clock); k != i32(rt.Key.None); k = rt.poll_key(0) {
			if k == 'q' || k == i32(rt.Key.Esc) do return
			rt.ui_key(k)
		}
	}
}
