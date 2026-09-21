# TODO

Open work, most useful first. Each item says what is blocking it, if anything.

**TODO vs future.** A TODO is work that is decided and small enough to just do: it has an owner, and at most one thing blocking it. Anything still an idea, a design question or a bigger direction goes in a "future" list instead, with its reasoning kept as the record. In this repo the future-style items are under "Smaller items".

## Housekeeping

- A board source that calls a tool from `~/.local/bin` needs it on `boardd`'s PATH (`systemd/boardd.service` sets one). After changing the service file, `systemctl --user daemon-reload` and restart it.
- Rebuild the viewer after every shim change (`odin build viewer ...`, see README), then restart `boardd`. A stale viewer keeps the old widgets.

## Smaller items

- `BigText` widget. It lives in a separate crate (`tui-big-text`), so it adds a dependency. Only worth it if a board wants large numbers.
- Split decision: the Rust shim and Odin bindings could become a standalone wrapper, with `boardd` in another repo. Deferred on purpose; the repo stays as one for now.

## Done recently

Port everything but the ratatui wrapper to Odin (`docs/design.md`); live boards moved out of the repo to `~/.config/boardkit/boards`; `boardd` watches extra directories; `boardd --check` and `test.sh`; `boardd` status board (`/boardd` state); stream `stale` restart; `chart`, `linegauge`, `calendar`, `canvas`, `logo`, `mascot` widgets; state directory `~/.cache/boardkit`.
