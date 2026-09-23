# boardkit

Terminal dashboards from JSON, drawn with [ratatui](https://ratatui.rs) and driven from [Odin](https://odin-lang.org).
A thin Rust shim exposes ratatui over a C ABI (terminal, keys, layout, one call per widget). Everything else is Odin: specs, state, bindings, validation, and `boardd`, one binary that draws boards and puts them into [herdr](https://herdr.dev) panes. See `docs/design.md`: prefer Odin unless Rust is necessary.

## Requirements

Rust (cargo), Odin, and `jq` for the example boards. herdr only for the daemon; `boardd view` runs in any terminal.

## Install

    git clone https://github.com/jonesnc/boardkit && cd boardkit
    ./install.sh               # build, install and start the boardd user service
    ./install.sh --no-service  # build only

Run it again after a `git pull`; it rebuilds and restarts the service.

## Build and test

    ./test.sh    # builds the shim and boardd, runs the tests, validates boards

Or step by step:

    cargo build --release --manifest-path shim/Cargo.toml
    odin build boardd -out:boardd/boardd -extra-linker-flags:"-lgcc_s -lm -lpthread -ldl"
    odin test ratatui -extra-linker-flags:"-lgcc_s -lm -lpthread -ldl" -define:ODIN_TEST_THREADS=1

Rebuild the shim first whenever `shim/` changes; `boardd` links it statically.

## Quickstart

    boardd/boardd view examples/boards/widgets.json   # draw one board, no daemon (q quits)
    boardd/boardd                                     # the daemon, inside herdr
    cp examples/boards/chart.json boards/             # a pane opens; edit to hot-reload, delete to close

## Layout

- `shim/` Rust crate (`ratatui_shim`): a thin C ABI over ratatui. It draws one widget into one rect; it knows nothing about JSON.
- `ratatui/` Odin package: JSON specs and state, bindings, the widget catalog (`catalog.json`) and validation, streaming, scroll/focus, hot reload, a 60 fps frame clock, and the tests.
- `boardd/` the one binary: `boardd [root] [dir...]` runs the daemon, `boardd view <spec-or-board.json> [state.json]` draws one board, `boardd --check [dir...]` validates board files.
- `examples/boards/` ready-made boards (`bindings.json` shows `$state`, `$each`, `$if`). Copy one into a watched directory to show it.
- `boards/` local live boards, not in git. Keep your own boards in `~/.config/boardkit/boards/`, which is also watched.
- `install.sh` build and install; `systemd/boardd.service` the unit template it fills in. `docs/` design notes, TODO, and `writing-boards.md` (read before writing a board that pulls from a real backend).

## Spec format

A spec is a tree of widgets: `block paragraph list table gauge linegauge sparkline chart barchart canvas calendar tabs scrollbar input popup logo mascot vstack hstack`.
Props and types are in `ratatui/catalog.json` (also printed as an LLM prompt by `catalog_prompt()`). A spec is validated when loaded:
unknown widgets or props, missing required props and wrong types are errors.

Data bindings (values come from live state, a JSON document):

- `{"$state": "/a/b"}` any prop value; a missing path drops the prop.
- `{"$each": "/arr", "size": "length:1", "template": {...}}` in a `children` array; `{"$item": "/field"}` inside.
- `"$if": "/flag"` on any node.
- `{"$pick": {"of": {"$state": "/pct"}, "rules": [[">=90","red"], ["~panic","red"]], "else": "green"}}` conditional values (colors, text). `~text` matches when the value contains text (any case).
- List items may be `{"text": .., "fg": ..}` and table rows `{"cells": [..], "fg": ..}` for colored rows.
- `"scroll": true, "id": "x"` on list/table/paragraph: Tab focuses, j/k/arrows/PgUp/PgDn/g/G scroll.

## Boards and boardd

A board is one JSON file: `{"herdr": {"tab","workspace","direction","ratio","parent"}, "sources": [...], "spec": {...}}`.
`herdr.tab` puts the board in its own herdr tab (found or created by label; boards sharing a label share the tab). `herdr.workspace` picks the workspace by label or id (default: the focused one). `parent` (a pane id or `board:<name>`) splits that pane instead. `"enabled": false` closes the pane but keeps the file.
`sources` are shell commands whose stdout is JSON, written into state at `into` (`every` seconds, or `"stream": true` for one JSON line per update; add `"stale": <secs>` to restart a stream that goes silent; `"timeout"` defaults to 10 s).
Watched directories: `<root>/boards` (root defaults to the repo that holds the binary), then extra args, then `$BOARDD_DIRS` (colon-separated) if set, else `~/.config/boardkit/boards`. Earlier directories win on a name clash.
A source may add a `judge` block: typed questions about its output (`noul` yes/no, `choice`, `score`), answered into state. With a [TypeSafe](https://docs.typesafe.ai) key (`$TYPESAFE_API_KEY` or `~/.config/boardkit/typesafe.key`) boardd asks the Jev model; without one, or if Jev fails, each question's `$pick`-style `rules`/`else` answer instead, so every board works without Jev. Answers are `{"value", "confidence", "by": "jev"|"rules", ...}`; see `ratatui/judge.odin` and `examples/boards/judge.json`.
Source failures and bad reloads show in a red banner on the bottom row. If a spec mentions `/herdr`, state includes herdr's workspaces, tabs, panes and layout; if it mentions `/boardd`, state includes every board's status, pane, tab, data age and errors (see `examples/boards/boardd.json`). State files live in `~/.cache/boardkit`.

`./install.sh` runs it as a systemd user service (logs: `journalctl --user -u boardd -f`). Open panes keep the old binary until they are reopened.

## From Odin

    import rt "ratatui"

    t := rt.init(); defer rt.restore(t)
    spec := rt.spec_load("ui.json")            // hot-reloads when the file changes
    rt.state_set_f64("/cpu", 0.42)             // or state_set_str / state_set_json / state_watch(file)
    clock := rt.clock_make(60)
    for {
        rt.draw(t, spec)                       // skips work if nothing changed
        for k := rt.frame_wait(&clock); k != i32(rt.Key.None); k = rt.poll_key(0) {
            if rt.ui_key(k) == 1 do continue   // scroll/focus keys
            if k == 'q' do return
        }
    }

Link with `-extra-linker-flags:"-lgcc_s -lm -lpthread -ldl"`; see `view` in `boardd/main.odin` for a complete program.

## Performance

A frame (resolve + render + diff) takes about 0.4 ms at 120x40 and 1.3 ms at 250x70 on a loaded machine (the `frame_cost` test logs it).
Idle boards draw nothing; a key press reaches the screen in about 1 ms.
