package ratatui

// Bindings: $state, $item, $each, $if, $pick. resolve builds a new tree in `allocator`; leaf
// strings are shared with the spec and state, so the result must not outlive either.

import "core:encoding/json"
import "core:strconv"
import "core:strings"

truthy :: proc(v: Value, found: bool) -> bool {
	if !found do return false
	switch x in v {
	case json.Null:    return false
	case json.Boolean: return bool(x)
	case json.Integer: return x != 0
	case json.Float:   return x != 0
	case json.String:  return len(x) > 0
	case json.Array:   return len(x) > 0
	case json.Object:  return len(x) > 0
	}
	return false
}

// Replace bindings with values. ok=false: drop this value (missing path or false $if).
resolve :: proc(v: Value, st: Value, item: Maybe(Value), allocator := context.temp_allocator) -> (out: Value, ok: bool) {
	context.allocator = allocator
	#partial switch m in v {
	case json.Object:
		if p, has_pick := m["$pick"]; has_pick do return pick(p, st, item)
		if p, has_state := m["$state"]; has_state {
			if s, is_str := as_str(p); is_str do return pointer(st, s)
		}
		if p, has_item := m["$item"]; has_item {
			if s, is_str := as_str(p); is_str {
				it := item.? or_return
				return pointer(it, s)
			}
		}
		if c, has_if := m["$if"]; has_if {
			cond: Value
			found: bool
			if s, is_str := as_str(c); is_str {
				cond, found = pointer(st, s)
			} else {
				cond, found = resolve(c, st, item)
			}
			if !truthy(cond, found) do return nil, false
		}
		o := make(json.Object, len(m))
		for k, val in m {
			if k == "$if" do continue
			if r, rok := resolve(val, st, item); rok do o[k] = r
		}
		return o, true
	case json.Array:
		a := make(json.Array, 0, len(m))
		for el in m {
			if p, has_each := get(el, "$each"); has_each {
				ps, _ := as_str(p)
				items, found := pointer(st, ps)
				arr, is_arr := items.(json.Array)
				tpl, has_tpl := get(el, "template")
				if !found || !is_arr || !has_tpl do continue
				size, has_size := get(el, "size")
				for it in arr {
					r, rok := resolve(tpl, st, it)
					if !rok do continue
					if o, is_obj := &r.(json.Object); is_obj && has_size && "size" not_in o do o["size"] = size
					append(&a, r)
				}
			} else if r, rok := resolve(el, st, item); rok {
				append(&a, r)
			}
		}
		return a, true
	}
	return v, true
}

// {"of": <value>, "rules": [[">=90","red"], ["~panic","red"], ...], "else": <value>}: first matching rule wins.
// "~text" matches when the value (as text) contains text, ignoring case.
pick :: proc(p: Value, st: Value, item: Maybe(Value)) -> (out: Value, ok: bool) {
	of_spec := get(p, "of") or_return
	of := resolve(of_spec, st, item) or_return
	return pick_on(p, of, st, item)
}

// The rules of a $pick applied to an already resolved value.
pick_on :: proc(p: Value, of: Value, st: Value, item: Maybe(Value)) -> (out: Value, ok: bool) {
	num, has_num := as_f64(of)
	text, has_text := as_str(of)
	if !has_num && has_text {
		num, has_num = parse_pct(text)
	}
	for r in array_of(p, "rules") {
		ra := as_array(r)
		if len(ra) < 2 do continue
		cond, is_str := as_str(ra[0])
		if !is_str do continue
		cond = strings.trim_space(cond)
		if strings.has_prefix(cond, "~") {
			hay := text if has_text else to_json(of, context.temp_allocator)
			if contains_fold(hay, cond[1:]) do return resolve(ra[1], st, item)
			continue
		}
		op, rhs := "==", cond
		for o in ([]string{"<=", ">=", "==", "!=", "<", ">"}) {
			if strings.has_prefix(cond, o) {
				op, rhs = o, strings.trim_space(cond[len(o):])
				break
			}
		}
		hit := false
		if b, bok := parse_pct(rhs); has_num && bok {
			a := num
			switch op {
			case "<=": hit = a <= b
			case ">=": hit = a >= b
			case "<":  hit = a < b
			case ">":  hit = a > b
			case "!=": hit = a != b
			case:      hit = a == b
			}
		} else {
			switch op {
			case "!=": hit = !has_text || text != rhs
			case "==": hit = has_text && text == rhs
			}
		}
		if hit do return resolve(ra[1], st, item)
	}
	e := get(p, "else") or_return
	return resolve(e, st, item)
}

@(private)
contains_fold :: proc(hay, needle: string) -> bool {
	if needle == "" do return true
	for i := 0; i + len(needle) <= len(hay); i += 1 {
		if strings.equal_fold(hay[i:i + len(needle)], needle) do return true
	}
	return false
}

@(private)
parse_pct :: proc(s: string) -> (f64, bool) {
	t := strings.trim_space(strings.trim_right(strings.trim_space(s), "%"))
	return strconv.parse_f64(t)
}
