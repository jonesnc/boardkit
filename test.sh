#!/bin/sh
# Build the shim, run the Odin tests, then validate every board file against the widget catalog.
set -e
cd "$(dirname "$0")"
FLAGS="-extra-linker-flags:-lgcc_s -lm -lpthread -ldl"
cargo build --release --manifest-path shim/Cargo.toml
odin test ratatui "$FLAGS" -define:ODIN_TEST_THREADS=1 # tests share the package globals (ui, state)
odin build boardd -out:boardd/boardd "$FLAGS"
./boardd/boardd --check
