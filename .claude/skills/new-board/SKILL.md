---
name: new-board
description: Create a new boardkit board (a terminal dashboard pane fed by shell commands) or change an existing one. Use when the user wants a board, dashboard, or pane for some data source — "make me a board for X", "add a pane showing Y", "board for oracle/redis/CI/disk" — or when a board is blank, stale, or showing a red banner.
---

# Adding a board

**Read `docs/writing-boards.md` in this repo first, in full.** It is the list of
mistakes that have already been made and it is short. Do not skip it because the
board looks simple; the failure modes there are silent, not loud.

Then follow this order. Steps 1 and 2 are where the time is saved — do not write
a spec before you have seen the data.

## 1. Probe every command by hand, sequentially

Run each candidate command once and look at the real output before designing
anything:

    <tool> --json <subcommand> | head -2

Check three things: it exits 0, it returns rows at all, and the key casing is
what you think it is. Commands that return zero rows on this environment get no
pane — an empty pane is indistinguishable from a broken one. Run the probes one
at a time; a burst of parallel probes can trip a backend connection limit.

**Then probe it again in a bare environment**, because that is what the service
gets. This has bitten every board so far — twice with the Oracle client, once
with `ORA-12154` from a missing `TNS_ADMIN`, once because `python3` resolved to
a system interpreter with no `oracledb`:

    env -i HOME=$HOME PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin <your script>

The unit sets only `HERDR_SOCKET_PATH` and that `PATH` (check with
`systemctl --user show boardd -p Environment`). Anything your interactive shell
exports — `ORACLE_HOME`, `LD_LIBRARY_PATH`, `TNS_ADMIN`, a pyenv shim, a
virtualenv — does not exist there. Pin what the tool needs **inside the script**
rather than in the unit, so a `./install.sh` cannot undo it. Pin an interpreter
by absolute path if the tool depends on a non-system one.

## 2. Decide the shape

Pick the widget from the data, not the reverse:
`table` for rows, `linegauge`/`gauge` for a ratio with a label, `barchart` for
labelled counts, `sparkline` for a series over time, `paragraph` for one labelled
number in a header row.

Prefer a rate or a delta over a cumulative total. A board that ranks by a
counter-since-startup barely changes between refreshes and hides the present.

If a pane must classify free text (log lines, alerts), add a `judge` block to the source instead of a long jq keyword chain. Read "Judging text" in `docs/writing-boards.md` first. Every question needs `rules` and `else`: the board must work with no TypeSafe key.

## 3. One source per board

Write the queries into a jobs file, `~/.config/boardkit/jobs/<name>.json`:

    [
      {"into": "w", "args": ["dba", "waits", "-c", "12"], "jq": "{rows: [...]}"},
      {"into": "x", "sql": "SELECT ...", "jq": "{rows: [...]}"}
    ]

The board then has exactly one source that runs them sequentially and merges the
results:

    "sources": [{
      "cmd": "$HOME/.config/boardkit/bin/lens-snap $HOME/.config/boardkit/jobs/<name>.json",
      "every": 60, "timeout": 300, "into": "/"
    }]

`into: "/"` makes each job's key a top-level state path, so `{"into": "w"}` is
read as `/w` in the spec. **Never put `tool | jq` directly in a `cmd`** — see the
doc for why.

### Existing helpers in `~/.config/boardkit/bin/`

Read the one closest to your backend before writing a new script.

- `lens-pprd` — pins the Oracle env, forces `--json`, `exec`s the tool.
- `lensq '<jq>' <args...>` — one query, propagates the tool's exit code.
- `lens-snap <jobs.json>` — many queries sequentially, merged into one object.
  This is the shape to copy for any connection-limited backend.
- `topsql-pprd.sh` — delta ranking against a cached previous sample.

### The snippet every new source script starts from

    #!/usr/bin/env bash
    # <what this feeds>. A script, not a board `cmd`: boardd runs sources with
    # `sh -c` (dash, no pipefail), so `tool | jq` would return jq's status and a
    # dead backend would draw an empty, all-clear board.
    set -uo pipefail

    # The boardd service starts with a bare environment (HERDR_SOCKET_PATH and a
    # minimal PATH). Pin here what the tool needs, not in the unit.
    export TNS_ADMIN=${TNS_ADMIN:-/usr/local/oracle}
    PATH=$HOME/.local/bin:$PATH

    out=$(<tool> --json <args>) || exit 1     # `|| exit 1` is the whole point
    [ -n "$out" ] || exit 1                   # empty output is a failure, not "no rows"

    printf '%s' "$out" | jq -c '<program>'    # add -s if the tool emits JSON lines

Then `chmod +x` it and verify with the `env -i` line from step 1.

## 4. Write the board file

`~/.config/boardkit/boards/<name>-<env>.json`, never the repo's `boards/`.

    "herdr": {"workspace": "boardd", "tab": "<short name>", "direction": "right", "ratio": 0.5}

The workspace must already exist. Check with `herdr workspace list`; create it
with `herdr workspace create --label <name> --no-focus` before the board is
written, or boardd logs `workspace ... not found`.

Label every number in the jq output, not in the spec
(`"txns " + (.TXN_COUNT|tostring)`). Put counts and status in the enclosing
`block` title via `{"$state": "/x/hdr"}` so an empty pane still says why.

## 5. Verify — three checks, all of them

    boardd/boardd --check                       # spec valid against the catalog

    sh -c "$HOME/.config/boardkit/bin/lens-snap $HOME/.config/boardkit/jobs/<name>.json"
                                                # rc=0 AND real rows

    journalctl --user -u boardd -n 10 --no-pager    # "added", "pane ... opened", no error line
    jq -c '{e: (._errors // "none")}' ~/.cache/boardkit/<name>.json

A pane can open while the source fails, so `pane ... opened` alone is not
success. **`sources ok` only logs when a board recovers from an error, so a
clean first run never prints it** — do not wait for that line, and do not grep
for it without a timestamp, or you will match a previous board's.

For a new board the success signal is: an `added` line, a `pane ... opened`
line, no `source N: rc=...` line after them, and a state file in
`~/.cache/boardkit/` holding real values with no `_errors`. The source reruns on
its `every` interval, so after fixing a script wait one interval rather than
restarting the service.

`--check` never runs the sources, so it cannot see a binding pointing at a key
that does not exist. Diff the source's actual keys against every `$state` path in
the spec yourself. A blank pane usually means a wrong path, not missing data.

## 6. Report

Say what the board shows, name one or two real values it returned, and state
plainly anything you left out and why (a command with no rows, a pane that needs
a fix elsewhere). Boards live outside the repo, so nothing here needs committing
unless you changed boardkit itself.
