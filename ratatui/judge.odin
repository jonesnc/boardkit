package ratatui

// Judge: typed questions about a source's output. boardd asks TypeSafe's Jev when an API key is
// set; otherwise, and for any question Jev does not answer, it uses the question's $pick-style
// "rules" and "else". A board works the same without Jev as long as its questions have rules.
//
//   "judge": {"into": "/verdict", "of": "/log", "every": 2, "questions": {
//     "failing":  {"type": "noul",   "instructions": "Does this log report a failure?",
//                  "criteria": {"true": "a job failed", "false": "all jobs ok"},
//                  "rules": [["~error", true], ["~fail", true]], "else": false},
//     "severity": {"type": "score",  "instructions": "How bad is it?", "criteria": ["ok", "degraded", "down"],
//                  "rules": [["~down", 2], ["~slow", 1]], "else": 0},
//     "area":     {"type": "choice", "instructions": "Which part is affected?",
//                  "criteria": {"disk": "storage, quotas", "net": "dns, timeouts"}, "rules": [["~dns", "net"]], "else": "disk"}}}
//
// Answers land at <into>/<question>:
//   noul   {"value": 0.93, "yes": true, "by": "jev"}
//   choice {"value": "net", "confidence": 0.8, "probabilities": {...}, "by": "jev"}
//   score  {"value": 1.05, "level": 1, "label": "degraded", "confidence": 0.9, "probabilities": {...}, "by": "jev"}
// Rule answers have "by": "rules" and confidence 1. A question with no answer is left out.

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:strings"

JUDGE_MODEL :: "jev-latest"

// Check a source's "judge" block. Returns "" when it is valid.
validate_judge :: proc(jd: Value) -> string {
	if _, is_obj := jd.(json.Object); !is_obj do return "judge must be an object"
	if str_of(jd, "into") == "" do return "judge needs \"into\""
	qv, _ := get(jd, "questions")
	qs, is_obj := qv.(json.Object)
	if !is_obj || len(qs) == 0 do return "judge needs \"questions\" (an object)"
	for k in sorted_keys(qs) {
		q := qs[k]
		if str_of(q, "instructions") == "" do return fmt.tprintf("judge question %q needs \"instructions\"", k)
		c, has_c := get(q, "criteria")
		switch str_of(q, "type") {
		case "noul":
			if has_c {
				if _, ok := c.(json.Object); !ok do return fmt.tprintf("judge question %q: noul \"criteria\" must be {\"true\": .., \"false\": ..}", k)
			}
		case "choice":
			if o, ok := c.(json.Object); !ok || len(o) < 2 do return fmt.tprintf("judge question %q: choice needs \"criteria\", an object of 2+ options", k)
		case "score":
			if len(as_array(c)) < 2 do return fmt.tprintf("judge question %q: score needs \"criteria\", an array of 2+ levels", k)
		case:
			return fmt.tprintf("judge question %q: \"type\" must be noul, choice or score", k)
		}
		if r, has_r := get(q, "rules"); has_r {
			if _, ok := r.(json.Array); !ok do return fmt.tprintf("judge question %q: \"rules\" must be an array", k)
		}
	}
	return ""
}

// The Jev request body. Only type, instructions and criteria go to Jev; rules stay local.
judge_request :: proc(jd: Value, state: Value, allocator := context.temp_allocator) -> string {
	context.allocator = allocator
	qs := make(json.Object)
	qv, _ := get(jd, "questions")
	for k, q in qv.(json.Object) or_else nil {
		o := make(json.Object)
		for f in ([]string{"type", "instructions", "criteria"}) {
			if v, ok := get(q, f); ok do o[f] = v
		}
		qs[k] = o
	}
	model := str_of(jd, "model")
	body := make(json.Object)
	body["state"] = state
	body["model"] = json.String(model if model != "" else JUDGE_MODEL)
	body["questions"] = qs
	return to_json(body)
}

// All answers for `state`: Jev's where `jev` (a parsed response) has them, rules for the rest.
// The result is owned by `allocator`.
judge_answers :: proc(jd: Value, state: Value, jev: Maybe(Value), allocator := context.allocator) -> Value {
	out := make(json.Object, allocator = allocator)
	qv, _ := get(jd, "questions")
	answers, _ := get(jev.? or_else nil, "answers")
	for k, q in qv.(json.Object) or_else nil {
		a, ok := from_jev(q, answers, k, allocator)
		if !ok do a, ok = from_rules(q, state, allocator)
		if ok do out[strings.clone(k, allocator)] = a
	}
	return out
}

@(private = "file")
from_jev :: proc(q: Value, answers: Value, key: string, allocator := context.allocator) -> (out: Value, ok: bool) {
	a := get(answers, key) or_return
	context.allocator = allocator
	o := make(json.Object)
	switch str_of(q, "type") {
	case "noul":
		p := as_f64(get(a, "noul") or_return) or_return
		put(&o, "value", json.Float(p))
		put(&o, "yes", json.Boolean(p >= 0.5))
	case "choice":
		c := as_str(get(a, "choice") or_return) or_return
		put(&o, "value", json.String(strings.clone(c)))
	case "score":
		s := as_f64(get(a, "score") or_return) or_return
		put(&o, "value", json.Float(s))
		set_level(&o, q, s)
	}
	if len(o) == 0 {
		delete(o)
		return nil, false
	}
	if c, has_c := f64_of(a, "confidence"); has_c do put(&o, "confidence", json.Float(c))
	if p, has_p := get(a, "probabilities"); has_p do put(&o, "probabilities", clone(p))
	put(&o, "by", json.String(strings.clone("jev")))
	return o, true
}

@(private = "file")
from_rules :: proc(q: Value, state: Value, allocator := context.allocator) -> (out: Value, ok: bool) {
	if !has(q, "rules") && !has(q, "else") do return nil, false
	r: Value
	{
		context.allocator = context.temp_allocator
		r = pick_on(q, state, nil, nil) or_return
	}
	context.allocator = allocator
	o := make(json.Object)
	switch str_of(q, "type") {
	case "noul":
		p, is_num := as_f64(r)
		if b, is_b := as_bool(r); is_b do p, is_num = (1 if b else 0), true
		if is_num {
			put(&o, "value", json.Float(p))
			put(&o, "yes", json.Boolean(p >= 0.5))
		}
	case "choice":
		if c, is_str := as_str(r); is_str do put(&o, "value", json.String(strings.clone(c)))
	case "score":
		if s, is_num := as_f64(r); is_num {
			put(&o, "value", json.Float(s))
			set_level(&o, q, s)
		}
	}
	if len(o) == 0 {
		delete(o)
		return nil, false
	}
	put(&o, "confidence", json.Float(1))
	put(&o, "by", json.String(strings.clone("rules")))
	return o, true
}

// "level" (nearest criteria index) and its "label" for a score.
@(private = "file")
set_level :: proc(o: ^json.Object, q: Value, s: f64) {
	levels := array_of(q, "criteria")
	if len(levels) == 0 do return
	i := clamp(int(math.round(s)), 0, len(levels) - 1)
	put(o, "level", json.Integer(i))
	if l, ok := as_str(levels[i]); ok do put(o, "label", json.String(strings.clone(l)))
}

// Keys are cloned so `destroy` can free the whole answer.
@(private = "file")
put :: proc(o: ^json.Object, k: string, v: Value) {
	o[strings.clone(k)] = v
}
