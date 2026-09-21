package ratatui

// JSON helpers over core:encoding/json. Values are parsed with integers kept as Integer.

import "core:encoding/json"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"

Value :: json.Value

// Parse one JSON document; anything after it is an error. Numbers parse as floats (json's integer
// mode wraps values above i64 max), then whole ones below 1e15 become Integer (see norm).
// On error, v is already freed.
parse_json :: proc(text: string, allocator := context.allocator) -> (v: Value, err: json.Error) {
	context.allocator = allocator
	p := json.make_parser_from_string(text, .JSON, false, allocator)
	v, err = json.parse_value(&p)
	if err == nil && p.curr_token.kind != .EOF do err = .Unexpected_Token
	if err != nil {
		destroy(v)
		return nil, err
	}
	norm(&v)
	return
}

get :: proc(v: Value, key: string) -> (Value, bool) {
	o, ok := v.(json.Object)
	if !ok do return nil, false
	return o[key]
}

has :: proc(v: Value, key: string) -> bool {
	_, ok := get(v, key)
	return ok
}

str_of :: proc(v: Value, key: string) -> string {
	x, _ := get(v, key)
	s, _ := x.(json.String)
	return string(s)
}

as_f64 :: proc(v: Value) -> (f64, bool) {
	#partial switch n in v {
	case json.Integer: return f64(n), true
	case json.Float:   return f64(n), true
	}
	return 0, false
}

// Non-negative whole number (a whole float like 3.0 counts).
as_uint :: proc(v: Value) -> (u64, bool) {
	#partial switch n in v {
	case json.Integer: if n >= 0 do return u64(n), true
	case json.Float:   if n >= 0 && math.trunc(n) == n && n < 1.8e19 do return u64(n), true
	}
	return 0, false
}

as_bool :: proc(v: Value) -> (bool, bool) {
	b, ok := v.(json.Boolean)
	return bool(b), ok
}

as_str :: proc(v: Value) -> (string, bool) {
	s, ok := v.(json.String)
	return string(s), ok
}

as_array :: proc(v: Value) -> []Value {
	a, _ := v.(json.Array)
	return a[:]
}

f64_of :: proc(v: Value, key: string) -> (f64, bool) {
	x, _ := get(v, key)
	return as_f64(x)
}

uint_of :: proc(v: Value, key: string) -> (u64, bool) {
	x, _ := get(v, key)
	return as_uint(x)
}

is_true :: proc(v: Value, key: string) -> bool {
	x, _ := get(v, key)
	b, _ := as_bool(x)
	return b
}

array_of :: proc(v: Value, key: string) -> []Value {
	x, _ := get(v, key)
	return as_array(x)
}

// String elements of an array prop (non-strings skipped). Allocates with `allocator`.
strings_of :: proc(v: Value, key: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	for e in array_of(v, key) {
		if s, ok := as_str(e); ok do append(&out, s)
	}
	return out[:]
}

// Object keys in sorted order (serde_json's default map order).
sorted_keys :: proc(o: json.Object, allocator := context.temp_allocator) -> []string {
	keys := make([]string, len(o), allocator)
	i := 0
	for k in o {
		keys[i] = k
		i += 1
	}
	slice.sort(keys)
	return keys
}

kind_name :: proc(v: Value) -> string {
	switch _ in v {
	case json.Null:    return "null"
	case json.Boolean: return "bool"
	case json.Integer, json.Float: return "number"
	case json.String:  return "string"
	case json.Array:   return "array"
	case json.Object:  return "object"
	}
	return "null"
}

// RFC 6901 pointer lookup. "" is the root; anything else must start with "/".
pointer :: proc(v: Value, ptr: string) -> (Value, bool) {
	if ptr == "" do return v, true
	if ptr[0] != '/' do return nil, false
	cur := v
	rest := ptr[1:]
	for {
		seg, more := next_segment(&rest)
		#partial switch c in cur {
		case json.Object:
			x, ok := c[seg]
			if !ok do return nil, false
			cur = x
		case json.Array:
			i, ok := strconv.parse_uint(seg, 10)
			if !ok || int(i) >= len(c) do return nil, false
			cur = c[i]
		case:
			return nil, false
		}
		if !more do return cur, true
	}
}

@(private)
next_segment :: proc(rest: ^string) -> (seg: string, more: bool) {
	i := strings.index_byte(rest^, '/')
	raw := rest^ if i < 0 else rest^[:i]
	more = i >= 0
	rest^ = "" if i < 0 else rest^[i + 1:]
	if strings.index_byte(raw, '~') < 0 do return raw, more
	s, _ := strings.replace_all(raw, "~1", "/", context.temp_allocator)
	s, _ = strings.replace_all(s, "~0", "~", context.temp_allocator)
	return s, more
}

equal :: proc(a, b: Value) -> bool {
	switch x in a {
	case json.Null:
		_, ok := b.(json.Null)
		return ok || b == nil
	case json.Boolean:
		y, ok := b.(json.Boolean)
		return ok && x == y
	case json.Integer:
		#partial switch y in b {
		case json.Integer: return x == y
		case json.Float:   return f64(x) == f64(y)
		}
		return false
	case json.Float:
		#partial switch y in b {
		case json.Integer: return f64(x) == f64(y)
		case json.Float:   return x == y
		}
		return false
	case json.String:
		y, ok := b.(json.String)
		return ok && x == y
	case json.Array:
		y, ok := b.(json.Array)
		if !ok || len(x) != len(y) do return false
		for e, i in x do if !equal(e, y[i]) do return false
		return true
	case json.Object:
		y, ok := b.(json.Object)
		if !ok || len(x) != len(y) do return false
		for k, e in x {
			f, found := y[k]
			if !found || !equal(e, f) do return false
		}
		return true
	}
	return b == nil
}

// Deep copy with `allocator`.
clone :: proc(v: Value, allocator := context.allocator) -> Value {
	context.allocator = allocator
	switch x in v {
	case json.Null, json.Boolean, json.Integer, json.Float:
		return x
	case json.String:
		return json.String(strings.clone(string(x)))
	case json.Array:
		out := make(json.Array, len(x))
		for e, i in x do out[i] = clone(e)
		return out
	case json.Object:
		out := make(json.Object, len(x))
		for k, e in x do out[strings.clone(k)] = clone(e)
		return out
	}
	return nil
}

destroy :: proc(v: Value, allocator := context.allocator) {
	json.destroy_value(v, allocator)
}

// Whole floats (1.0) become ints so integer props like `selected` accept them. In place.
norm :: proc(v: ^Value) {
	#partial switch &x in v^ {
	case json.Float:
		if math.trunc(x) == x && abs(x) < 1e15 do v^ = json.Integer(i64(x))
	case json.Array:
		for &e in x do norm(&e)
	case json.Object:
		for _, &e in x do norm(&e)
	}
}

// Set `val` at pointer `ptr` in `root` (heap-owned tree), creating objects on the way. "" or "/"
// replaces the root. Takes ownership of `val`; frees what it replaces. An array index that is out
// of range drops `val`.
set_ptr :: proc(root: ^Value, ptr: string, val: Value, allocator := context.allocator) {
	context.allocator = allocator
	if ptr == "" || ptr == "/" {
		destroy(root^)
		root^ = val
		return
	}
	cur := root
	rest := strings.trim_left(ptr, "/")
	for {
		seg, more := next_segment(&rest)
		if arr, ok := &cur.(json.Array); ok {
			i, pok := strconv.parse_uint(seg, 10)
			if !pok || int(i) >= len(arr) {
				destroy(val)
				return
			}
			cur = &arr[i]
		} else {
			if _, is_obj := cur.(json.Object); !is_obj {
				destroy(cur^)
				cur^ = make(json.Object)
			}
			obj := &cur.(json.Object)
			if seg not_in obj do obj[strings.clone(seg)] = json.Null{}
			cur = &obj[seg]
		}
		if !more do break
	}
	destroy(cur^)
	cur^ = val
}

// Serialize compactly (object keys sorted).
to_json :: proc(v: Value, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	write_json(&b, v)
	return strings.to_string(b)
}

write_json :: proc(b: ^strings.Builder, v: Value) {
	switch x in v {
	case json.Null:
		strings.write_string(b, "null")
	case json.Boolean:
		strings.write_string(b, "true" if x else "false")
	case json.Integer:
		strings.write_i64(b, i64(x))
	case json.Float:
		if math.is_nan(x) || math.is_inf(x) {
			strings.write_string(b, "null")
		} else {
			buf: [64]u8
			strings.write_string(b, strings.trim_prefix(strconv.write_float(buf[:], f64(x), 'g', -1, 64), "+"))
		}
	case json.String:
		write_json_string(b, string(x))
	case json.Array:
		strings.write_byte(b, '[')
		for e, i in x {
			if i > 0 do strings.write_byte(b, ',')
			write_json(b, e)
		}
		strings.write_byte(b, ']')
	case json.Object:
		strings.write_byte(b, '{')
		for k, i in sorted_keys(x) {
			if i > 0 do strings.write_byte(b, ',')
			write_json_string(b, k)
			strings.write_byte(b, ':')
			write_json(b, x[k])
		}
		strings.write_byte(b, '}')
	case:
		strings.write_string(b, "null")
	}
}

write_json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i in 0 ..< len(s) {
		c := s[i]
		switch c {
		case '"':  strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r': strings.write_string(b, `\r`)
		case '\t': strings.write_string(b, `\t`)
		case:
			if c < 0x20 {
				strings.write_string(b, `\u00`)
				hex := "0123456789abcdef"
				strings.write_byte(b, hex[c >> 4])
				strings.write_byte(b, hex[c & 15])
			} else {
				strings.write_byte(b, c)
			}
		}
	}
	strings.write_byte(b, '"')
}
