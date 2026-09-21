#!/bin/sh
# Build boardd and install it as a systemd user service. Safe to run again after a pull.
#   ./install.sh               build, install the service, (re)start it
#   ./install.sh --no-service  build only
set -e
cd "$(dirname "$0")"
root=$(pwd)

for tool in cargo odin; do
	command -v "$tool" >/dev/null || { echo "install.sh: $tool not found" >&2; exit 1; }
done
for tool in herdr jq; do
	command -v "$tool" >/dev/null || echo "install.sh: warning: $tool not found (herdr: needed by the daemon; jq: used by the example boards)"
done

cargo build --release --manifest-path shim/Cargo.toml
odin build boardd -out:boardd/boardd -extra-linker-flags:"-lgcc_s -lm -lpthread -ldl"
mkdir -p "$HOME/.config/boardkit/boards"
echo "built $root/boardd/boardd; put boards in ~/.config/boardkit/boards"

[ "$1" = "--no-service" ] && exit 0
command -v systemctl >/dev/null || { echo "install.sh: no systemctl; run boardd/boardd inside herdr instead"; exit 0; }
unit="$HOME/.config/systemd/user/boardd.service"
mkdir -p "$(dirname "$unit")"
sed "s#@BOARDKIT@#$root#" systemd/boardd.service > "$unit"
systemctl --user daemon-reload
systemctl --user enable --now boardd
systemctl --user restart boardd # pick up a rebuilt binary
echo "boardd service: $(systemctl --user is-active boardd) (logs: journalctl --user -u boardd -f)"
