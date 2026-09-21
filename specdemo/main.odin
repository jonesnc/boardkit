package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:time"
import rt "../ratatui"

NAMES :: [4]string{"nginx", "postgres", "redis", "odin-demo"}

push_procs :: proc(tick: int) {
	names := NAMES
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "[")
	for n, i in names {
		if i > 0 do strings.write_string(&b, ",")
		fmt.sbprintf(&b, `{{"line":"%s  pid %d  mem %d MB"}}`, n, 1000 + i * 37, 100 + (tick * (i + 1)) % 400)
	}
	strings.write_string(&b, "]")
	rt.state_set_json("/procs", strings.to_cstring(&b))
	rt.state_set_json("/names", `["nginx","postgres","redis","odin-demo"]`)
}

main :: proc() {
	dash := rt.spec_load("specdemo/dash.json")
	help := rt.spec_load("specdemo/help.json")
	if dash == nil || help == nil {
		fmt.eprintln("load failed:", rt.last_error())
		os.exit(1)
	}
	t := rt.init()
	defer rt.restore(t)

	names := NAMES
	sel, screen := 0, 0
	confirm := false
	clock := rt.clock_make(60)
	rt.state_set_json("/", `{"screen":0,"sel":0,"confirm":false}`)
	start := time.tick_now()
	for {
		tick := int(time.duration_milliseconds(time.tick_since(start)) / 50)
		cpu := 0.5 + 0.4 * math.sin(time.duration_seconds(time.tick_since(start)) * 1.2)
		rt.state_set_f64("/cpu", cpu)
		rt.state_set_str("/cpu_label", strings.clone_to_cstring(fmt.tprintf("CPU %.0f%%", cpu * 100), context.temp_allocator))
		rt.state_set_str("/popup_text", strings.clone_to_cstring(fmt.tprintf("Kill %s? (p to close)", names[sel]), context.temp_allocator))
		push_procs(tick)
		rt.state_set_f64("/sel", f64(sel))
		rt.state_set_f64("/screen", f64(screen))
		rt.state_set_json("/confirm", confirm ? "true" : "false")

		rt.draw(t, screen == 0 ? dash : help)

		for k := rt.frame_wait(&clock); k != i32(rt.Key.None); k = rt.poll_key(0) {
			switch k {
			case 'q': return
			case 'j': sel = min(sel + 1, len(names) - 1)
			case 'k': sel = max(sel - 1, 0)
			case 'p': confirm = !confirm
			case '1': screen = 0
			case '2': screen = 1
			}
		}
	}
}
