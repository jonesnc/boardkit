package ratatui

// The widget catalog: allowed components and props. Validates specs and renders an LLM prompt.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"
import "core:strings"

CATALOG_TEXT :: #load("catalog.json", string)

@(private)
catalog_value: Value

catalog :: proc() -> Value {
	if catalog_value == nil {
		v, err := parse_json(CATALOG_TEXT, runtime.heap_allocator()) // cached for the process
		fmt.assertf(err == nil, "catalog.json: %v", err)
		catalog_value = v
	}
	return catalog_value
}

// A system-prompt fragment telling an LLM how to emit a valid spec.
catalog_prompt_text :: proc(allocator := context.allocator) -> string {
	c := catalog()
	b := strings.builder_make(allocator)
	strings.write_string(&b, "Output ONLY one JSON object: a UI tree for a terminal. Every node has a \"type\" and the props below.\n\nComponents:\n")
	comps, _ := get(c, "components")
	co, _ := comps.(json.Object)
	for name in sorted_keys(co) {
		d := co[name]
		po, _ := get(d, "props")
		props := make([dynamic]string, context.temp_allocator)
		for k in sorted_keys(po.(json.Object) or_else nil) {
			append(&props, fmt.tprintf("%s: %s", k, str_of(po, k)))
		}
		req := strings_of(d, "required")
		fmt.sbprintf(&b, "- %s: %s Props: %s. Required: %s.\n", name, str_of(d, "description"), strings.join(props[:], ", ", context.temp_allocator),
			"none" if len(req) == 0 else strings.join(req, ", ", context.temp_allocator))
	}
	so, _ := get(c, "style")
	style := make([dynamic]string, context.temp_allocator)
	for k in sorted_keys(so.(json.Object) or_else nil) {
		append(&style, fmt.tprintf("%s: %s", k, str_of(so, k)))
	}
	fmt.sbprintf(&b, "\nAny component also accepts style props: %s.\nConstraint strings: %s.\n", strings.join(style[:], ", ", context.temp_allocator), str_of(c, "constraint"))
	strings.write_string(&b, "\nData bindings:\n")
	for s in strings_of(c, "bindings") do fmt.sbprintf(&b, "- %s\n", s)
	return strings.to_string(b)
}

is_binding :: proc(v: Value) -> bool {
	return has(v, "$state") || has(v, "$item") || has(v, "$pick")
}

@(private)
is_uint :: proc(v: Value) -> bool {
	_, ok := as_uint(v)
	return ok
}

// "length:3" | "percent:50" | "min:2" | "max:9" | "fill:1" | "fill" (default n = 1).
parse_constraint :: proc(s: string) -> (c: Cons, ok: bool) {
	kind, n := s, "1"
	if i := strings.index_byte(s, ':'); i >= 0 do kind, n = s[:i], s[i + 1:]
	v, nok := strconv.parse_uint(n, 10)
	switch kind {
	case "length":  c.kind = 1
	case "percent": c.kind = 2
	case "min":     c.kind = 3
	case "max":     c.kind = 4
	case "fill":    c.kind = 0
	case:           return {0, u16(v) if nok && v <= 65535 else 1}, false
	}
	ok = nok && v <= 65535
	c.n = u16(v) if ok else 1
	return
}

color_valid :: proc(s: string) -> bool {
	s := s
	return rt_color_ok(&s) != 0
}

@(private)
all_of :: proc(a: Value, f: proc(e: Value) -> bool) -> bool {
	arr, ok := a.(json.Array)
	if !ok do return false
	for e in arr do if !is_binding(e) && !f(e) do return false
	return true
}

// Check one prop value against its catalog type string. Bindings are checked at runtime, not here.
type_ok :: proc(ty: string, v: Value) -> bool {
	if is_binding(v) do return true
	is_string :: proc(e: Value) -> bool { _, ok := e.(json.String); return ok }
	switch ty {
	case "string":      return is_string(v)
	case "bool":        _, ok := v.(json.Boolean); return ok
	case "int", "int percent": return is_uint(v)
	case "float 0..1":  f, ok := as_f64(v); return ok && f >= 0 && f <= 1
	case "string[]":    return all_of(v, is_string)
	case "int[]":       return all_of(v, is_uint)
	case "series[]":
		return all_of(v, proc(s: Value) -> bool {
			d, ok := get(s, "data")
			return ok && all_of(d, proc(p: Value) -> bool {
				return all_of(p, proc(n: Value) -> bool { _, ok := as_f64(n); return ok || is_binding(n) })
			})
		})
	case "string[][]":  return all_of(v, proc(r: Value) -> bool { return all_of(r, is_string) })
	case "row[]":
		return all_of(v, proc(r: Value) -> bool {
			if all_of(r, is_string) do return true
			c, ok := get(r, "cells")
			return ok && all_of(c, is_string)
		})
	case "item[]":
		return all_of(v, proc(e: Value) -> bool {
			if is_string(e) do return true
			t, ok := get(e, "text")
			return ok && is_string(t)
		})
	case "constraint[]":
		return all_of(v, proc(e: Value) -> bool { s, ok := as_str(e); _, cok := parse_constraint(s); return ok && cok })
	case "constraint":
		s, ok := as_str(v)
		_, cok := parse_constraint(s)
		return ok && cok
	case "[label, int][]":
		return all_of(v, proc(e: Value) -> bool {
			p, ok := e.(json.Array)
			return ok && len(p) == 2 && is_string(p[0]) && is_uint(p[1])
		})
	case "color name or #rrggbb":
		s, ok := as_str(v)
		return ok && color_valid(s)
	}
	if strings.contains_rune(ty, '|') {
		s, ok := as_str(v)
		if !ok do return false
		opts := ty
		for o in strings.split_iterator(&opts, "|") do if o == s do return true
		return false
	}
	return true // "component" / "component[]" are checked by recursion
}

// Validate a spec tree against the catalog. Returns "" if valid, else a message (temp allocated).
validate_spec :: proc(v: Value) -> string {
	return check(v, "$")
}

@(private)
check :: proc(v: Value, path: string) -> string {
	obj, ok := v.(json.Object)
	if !ok do return fmt.tprintf("%s: not an object", path)
	if "$each" in obj {
		t, tok := obj["template"]
		if !tok do return fmt.tprintf("%s: $each requires \"template\"", path)
		return check(t, fmt.tprintf("%s.template", path))
	}
	ty, tok := as_str(obj["type"] or_else nil)
	if !tok do return fmt.tprintf("%s: missing \"type\"", path)
	comps, _ := get(catalog(), "components")
	comp, cok := get(comps, ty)
	if !cok do return fmt.tprintf("%s: unknown component \"%s\"", path, ty)
	for r in strings_of(comp, "required") {
		if r not_in obj do return fmt.tprintf("%s: %s requires \"%s\"", path, ty, r)
	}
	props, _ := get(comp, "props")
	style, _ := get(catalog(), "style")
	for k in sorted_keys(obj) {
		switch k {
		case "type", "$if", "child", "children": continue
		}
		t, found := get(props, k)
		if !found do t, found = get(style, k)
		ts, _ := as_str(t)
		if !found {
			valid := make([dynamic]string, context.temp_allocator)
			for p in sorted_keys(props.(json.Object) or_else nil) do append(&valid, p)
			for p in sorted_keys(style.(json.Object) or_else nil) do append(&valid, p)
			return fmt.tprintf("%s: %s has no prop \"%s\" (valid: %s)", path, ty, k, strings.join(valid[:], ", ", context.temp_allocator))
		}
		if !type_ok(ts, obj[k]) do return fmt.tprintf("%s: %s.%s must be %s (got %s)", path, ty, k, ts, kind_name(obj[k]))
	}
	if is_true(v, "scroll") {
		id, has_id := obj["id"]
		_, is_str := id.(json.String)
		if !has_id || !(is_str || is_binding(id)) do return fmt.tprintf("%s: %s with scroll:true needs a string \"id\"", path, ty)
	}
	if kids, has_kids := obj["children"]; has_kids {
		arr, is_arr := kids.(json.Array)
		if !is_arr do return fmt.tprintf("%s: children must be an array", path)
		if c, has_child := obj["child"]; has_child {
			if e := check(c, fmt.tprintf("%s.child", path)); e != "" do return e
		}
		for k, i in arr {
			if e := check(k, fmt.tprintf("%s.children[%d]", path, i)); e != "" do return e
		}
		return ""
	}
	if c, has_child := obj["child"]; has_child {
		if e := check(c, fmt.tprintf("%s.child", path)); e != "" do return e
	}
	return ""
}
