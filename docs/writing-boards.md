# Writing boards

Lessons from building six live boards against an Oracle monitoring CLI. Read this
before writing a board that pulls from a real backend; every rule here cost a
debugging cycle to learn.

## The rule that matters most

**A failed source renders as an empty widget, not an error.** boardd runs sources
with `sh -c`, which is dash on most systems, and dash has no `pipefail`. So this:

    "cmd": "mytool --json | jq -s -c '{rows: [...]}'"

returns *jq's* exit status. When `mytool` dies, jq gets no input, emits
`{"rows": []}`, exits 0, and the board cheerfully draws an empty table. On a
monitoring board that is worse than a crash: a query that failed with an Oracle
error displayed as "no failed jobs in last 24h" — a false all-clear.

Never pipe a data command straight into jq. Put the pipeline in a script with a
`#!/usr/bin/env bash` shebang and `set -uo pipefail`, or capture first so the
exit status survives:

    out=$(mytool --json) || exit 1
    printf '%s' "$out" | jq -s -c "$prog"

A non-zero exit gives you the red banner, which is the entire point.

## Respect the backend's connection limit

Each source is an independent process, and sources fire concurrently. Fourteen
sources across four boards meant fourteen simultaneous database sessions against
a profile capped at five, which surfaced as `ORA-02391: exceeded simultaneous
SESSIONS_PER_USER limit` — intermittently, on whichever board lost the race.

Give each board **one** source that runs its queries sequentially and emits one
merged object, with `"into": "/"` so the object's keys become the top-level state
paths. A small driver that reads a list of `{into, args, jq}` entries and merges
each result under its key keeps this declarative and reusable across boards.

## Keep jq out of the JSON

A jq program inside a JSON string is double-escaped: `\"` for every quote and
`\\\\s+` for every regex. Those strings are unreadable and every edit is
guess-and-check. Keep the programs in a separate data file that the board's
script reads, so jq sees normal source text.

## Shape bugs are invisible to `--check`

`boardd --check` validates the spec against the catalog. It never runs the
sources, so it cannot see that `{"$state": "/x/rows"}` points at a source that
emits `/x/row`. A missing binding path silently drops the prop and the board just
looks empty. **Always run each source by hand and diff its keys against the spec
before trusting a blank pane.**

The mismatches that actually happened:

- Column case. The tool emitted `SQL_ID`; the jq read `.sql_id`. Normalize once
  in a `def`, or read the real casing.
- Columns whose names need bracket syntax: `.["ERROR#"]`, not `.ERROR#`.
- `null` leaking into a typed widget. A session with no module produced
  `[null, null]` in a barchart's `data`, which cannot be drawn. Filter with
  `select(.X != null)` before building `[label, value]` pairs.
- A `//` default on a *human-formatted* field while sorting on the raw one, so
  the sort and the display disagreed.

## Label every number you put on the board

A bare `1h 21m 14s` in a header taught nobody anything — the first question asked
was "what does this mean?". Build the label into the jq output
(`"txns " + (.TXN_COUNT|tostring)`), not into the reader's memory. The same goes
for a column like `GAINED`: if the semantics are not obvious from the header,
they belong in the block title.

## Aim for about 60 updates per second, degrade only when forced

The renderer is never the problem: a frame costs 0.25-0.8 ms and the viewer
redraws only when state changes. What makes a board look slow is the data path.
Measured ceilings, fastest first:

| source shape | updates/sec | what limits it |
|---|---|---|
| `stream` whose command loops in-process (`python3 -u`, `awk`) | ~51 | boardd coalesces writes to one per 16 ms (62/s) |
| `stream` spawning a process per line (`while :; do jq ...; done`) | ~30 | process spawn, ~34 ms each |
| polled `"every": 0.02` | ~16 | `timeout`+`sh`+`jq` per sample |
| polled `"every": 0.5` | 2 | the interval, as asked |

So: for anything that should animate, use a `stream` and keep the loop inside
one process. Use a polled source for anything you are sampling rather than
animating — a database query has its own latency floor and 60 fps is neither
possible nor wanted there.

Before blaming boardd, check the data expression. **jq's `%` is integer
modulo**, so `now % 60 / 60` yields only 60 distinct values and a gauge built on
it steps exactly once a second no matter how often the source runs. Use
`(now / 6) - (now / 6 | floor)` for a smooth sweep.

Two fixed 100 ms sleeps used to cap every source at ~10/s regardless of
settings (the stream drain loop, and `nap` for polled sources). Both are gone,
but if a board seems pinned near 10/s, check that the running daemon is not an
older binary: `md5sum /proc/$(systemctl --user show boardd -p MainPID --value)/exe
boardd/boardd`.

## Cumulative counters make a dead-looking board

Most `V$` style views report totals since the cursor or instance started. Ranking
by a cumulative column produces a table that barely changes between refreshes and
hides what is happening right now. Sample, cache the previous sample, and rank by
the delta:

- Write only the numeric fields you need to the cache, keyed by id.
- Clamp every delta at zero. A counter resets when its row ages out, and a
  negative delta will sort to the top and look like a crisis.
- On the first sample there is no previous one. Fall back to the cumulative
  ranking and *say so on the board* rather than showing zeros.
- Keep a rolling array of the top delta for a `sparkline`; trend is nearly free
  once you are already diffing samples.

## Judging text: ask small questions, keep rules as the floor

A `judge` block turns text (a log line, a status message) into typed answers you can color and gauge. Jev answers when a TypeSafe key is set; the question's `rules` answer otherwise. Write it so the board is right without the key:

- One property per question. "Did a job fail?" (noul) and "How bad?" (score) are two questions, not one "summarize the state".
- Give each question only the text it needs: point `of` at the field, not the whole document.
- Always give `rules` and `else`. They are the no-key path and the fallback when Jev is down. `~word` matches text in any case.
- Keep deterministic checks in the source or in `$pick`. Ask the judge only what needs judgment.
- Bind colors to `level` or `value`, not to `label` text. Show `by` somewhere quiet so you can tell which path answered.
- For tables, judge per row with `"each"` and color rows with `"set"`, not one question about the whole table. A row judgment ("is this item done?") is single-hop, which is what Jev is good at.
- `every` (default 2 s) is the fastest the judge asks; it asks only when the text changes. Jev calls never delay a frame or a source.

## Placement

`herdr.tab` is found-or-created, but **`herdr.workspace` must already exist** —
boardd looks it up by label and logs `workspace ... not found` otherwise. Create
it first (`herdr workspace create --label <name> --no-focus`), and keep the label
in the board file so the placement survives a restart. Renaming the workspace in
herdr without editing the board file breaks the lookup.

Boards belong in `~/.config/boardkit/boards/`, not the repo's `boards/` (which is
gitignored and exists for scratch use).

## Tool output is not always stable text

Values can be redacted or tokenized by the tool in front of the database. A
redacted module string came back as `EMAIL:3c26 (TNS V1-V3)` and the token
changed on every refresh. Do not build keys, joins or caches out of a field the
upstream tool may rewrite — and expect such values to differ between two calls
that should agree.

## Do not widen what you display just because you can

Truncated identifiers and SQL previews are often truncated on purpose. Widening a
`SUBSTR(sql_text, 1, 40)` preview to 200 characters pulls literal bind-free
values — ids, names, dates — onto a dashboard and into whatever cache file backs
it. Prefer the vetted, redacted command over hand-written SQL that bypasses it,
and fetch full text on demand instead of putting it in a refreshing pane.

## Work around client limits in the query, not the client

A driver that could not convert `TIMESTAMP WITH TIME ZONE` (a client missing its
timezone files) failed with `ORA-01805` — but only past a certain row count,
which makes it look like a size problem rather than a type problem. Formatting
server-side with `TO_CHAR(ts, 'YYYY-MM-DD HH24:MI:SS')` sends a plain string and
sidesteps the client entirely. Reach for a query-side fix before installing
software.

## Check that the data exists before designing the pane

Four planned panes (redo rate, log switches, RMAN backup jobs, unbacked-up
archive logs, parallel-query sessions) returned zero rows on that environment.
Probe each command once before you write a spec around it; an empty board is
indistinguishable from a broken one.

## A moved board file used to strand its pane

Fixed, but worth knowing the shape of the bug: a pane's viewer is launched with
the board file's path. `mv` preserves mtime, so the rescan skipped the board and
the viewer kept reading a path that no longer existed, banner up forever.
`Board.path` is now compared alongside the mtime, and the viewer retries a failed
reload. If you see a stale `reload failed: ... Not_Exist`, the running daemon
predates that fix — reopen the pane by toggling `"enabled": false` and back.
