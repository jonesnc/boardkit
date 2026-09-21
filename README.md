# boardkit

Terminal dashboards from JSON, drawn with [ratatui](https://ratatui.rs) and driven from [Odin](https://odin-lang.org) (formerly `odin-ratatui`).
A thin Rust shim exposes ratatui over a C ABI (terminal, keys, layout, one call per widget). Everything else is Odin: specs, state, bindings, validation, a generic viewer and `boardd` (a directory watcher that puts boards into [herdr](https://herdr.dev) panes). See `docs/design.md`: prefer Odin unless Rust is necessary.

## Quickstart

    ./test.sh                                   # build, run tests, validate boards
    cargo build --release --manifest-path shim/Cargo.toml
    odin build viewer -out:viewer/viewer -extra-linker-flags:"-lgcc_s -lm -lpthread -ldl"
    odin build boardd -out:boardd/boardd -extra-linker-flags:"-lgcc_s -lm -lpthread -ldl"
    viewer/viewer examples/boards/widgets.json  # one board, no daemon (q quits)
    cp examples/boards/chart.json boards/       # with boardd running in herdr: a pane opens

## Layout

- `shim/` Rust crate (`ratatui_shim`): a thin C ABI over ratatui. It draws one widget into one rect; it knows nothing about JSON.
- `ratatui/` Odin package: JSON specs and state, bindings, the widget catalog (`catalog.json`) and validation, streaming, scroll/focus, hot reload, plus a 60 fps frame clock.
- `boardd/` the board daemon (Odin).
- `viewer/` generic viewer: `viewer <spec-or-board.json> [state.json]`.
- `boards/` local live boards, not in git. Keep your own boards in `~/.config/boardkit/boards/` (also watched). `examples/boards/` are ready-made ones to copy in.
- `specdemo/` an interactive Odin program on the state API (its `dash.json` is also a test fixture); `claudedemo/` streams a spec from Claude.

## Build

    cargo build --release --manifest-path shim/Cargo.toml
    odin build viewer -out:viewer/viewer -extra-linker-flags:"-lgcc_s -lm -lpthread -ldl"
    odin build boardd -out:boardd/boardd -extra-linker-flags:"-lgcc_s -lm -lpthread -ldl"
    odin test ratatui -extra-linker-flags:"-lgcc_s -lm -lpthread -ldl" -define:ODIN_TEST_THREADS=1

## Spec format

A spec is a tree of widgets: `block paragraph list table gauge linegauge sparkline chart barchart canvas calendar tabs scrollbar input popup logo mascot vstack hstack`.
Props and types are in `ratatui/catalog.json` (also printed as an LLM prompt by `catalog_prompt()`). A spec is validated when loaded:
unknown widgets or props, missing required props and wrong types are errors.

Data bindings (values come from live state, a JSON document):

- `{"$state": "/a/b"}` any prop value; a missing path drops the prop.
- `{"$each": "/arr", "size": "length:1", "template": {...}}` in a `children` array; `{"$item": "/field"}` inside.
- `"$if": "/flag"` on any node.
- `{"$pick": {"of": {"$state": "/pct"}, "rules": [[">=90","red"]], "else": "green"}}` conditional values (colors, text).
- List items may be `{"text": .., "fg": ..}` and table rows `{"cells": [..], "fg": ..}` for colored rows.
- `"scroll": true, "id": "x"` on list/table/paragraph: Tab focuses, j/k/arrows/PgUp/PgDn/g/G scroll.

## Boards and boardd

A board is one JSON file: `{"herdr": {"tab","workspace","direction","ratio","parent"}, "sources": [...], "spec": {...}}`.
`herdr.tab` puts the board in its own herdr tab (found or created by label; boards sharing a label share the tab). `herdr.workspace` picks the workspace by label or id (default: the focused one). `parent` (a pane id or `board:<name>`) splits that pane instead.
`sources` are shell commands whose stdout is JSON, written into state at `into` (`every` seconds, or `"stream": true` for one JSON line per update; add `"stale": <secs>` to restart a stream that goes silent).
Extra board directories: `~/.config/boardkit/boards` is watched by default (or `$BOARDD_DIRS`, colon-separated; or extra args). Earlier directories win on a name clash. `boardd --check [dir...]` validates board files.
Run `boardd/boardd` inside herdr: a new file in `boards/` opens a pane running the viewer, edits hot-reload, deleting closes it.
Source failures and bad reloads show in a red banner on the bottom row. If a spec mentions `/herdr`, state includes herdr's workspaces, tabs, panes and layout; if it mentions `/boardd`, state includes every board's status, pane, tab, data age and errors (see `examples/boards/boardd.json`). State files live in `~/.cache/boardkit`.
`systemd/boardd.service` runs it as a user service. Install it from the repo root: `sed "s#@BOARDKIT@#$PWD#" systemd/boardd.service > ~/.config/systemd/user/boardd.service`, then `systemctl --user daemon-reload && systemctl --user enable --now boardd`. Restart it after rebuilding.

## From Odin

    rt := ...
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

## Performance

A frame (resolve + render + diff) takes about 0.4 ms at 120x40 and 1.3 ms at 250x70 on a loaded machine (the `frame_cost` test in `ratatui/ratatui_test.odin` logs it).
Idle UIs draw nothing (0.3% CPU); a key press reaches the screen in about 1 ms.
