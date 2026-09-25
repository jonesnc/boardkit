#!/bin/sh
# Build boardd and install it as a systemd user service. Safe to run again after a pull.
#   ./install.sh               build, install the service, (re)start it
#   ./install.sh --no-service  build only
set -e
cd "$(dirname "$0")"
root=$(pwd)

# Install the latest Odin release to ~/.local/share/odin (linked into ~/.local/bin) if odin is missing.
install_odin() {
	command -v gh >/dev/null || { echo "install.sh: odin not found, and gh is needed to fetch it" >&2; exit 1; }
	case "$(uname -s)-$(uname -m)" in
	Linux-x86_64) plat=linux-amd64 ;;
	Linux-aarch64) plat=linux-arm64 ;;
	Darwin-x86_64) plat=macos-amd64 ;;
	Darwin-arm64) plat=macos-arm64 ;;
	*) echo "install.sh: no Odin release for $(uname -sm); install odin by hand" >&2; exit 1 ;;
	esac
	echo "==> odin not found: installing the latest Odin release ($plat) to ~/.local/share/odin"
	tmp=$(mktemp -d)
	gh release download -R odin-lang/Odin -p "odin-$plat-*.tar.gz" -D "$tmp"
	echo "==> unpacking Odin"
	rm -rf "$HOME/.local/share/odin"
	mkdir -p "$HOME/.local/share/odin" "$HOME/.local/bin"
	tar xzf "$tmp"/odin-*.tar.gz -C "$HOME/.local/share/odin" --strip-components=1
	rm -rf "$tmp"
	ln -sf "$HOME/.local/share/odin/odin" "$HOME/.local/bin/odin"
	export PATH="$HOME/.local/bin:$PATH"
	echo "==> installed $(odin version) at ~/.local/bin/odin"
	case ":$PATH_BEFORE:" in *":$HOME/.local/bin:"*) ;; *) echo "==> note: add ~/.local/bin to your PATH to use odin outside this script" ;; esac
}
PATH_BEFORE=$PATH
[ -x "$HOME/.local/bin/odin" ] && export PATH="$HOME/.local/bin:$PATH"
command -v odin >/dev/null || install_odin

for tool in cargo odin; do
	command -v "$tool" >/dev/null || { echo "install.sh: $tool not found" >&2; exit 1; }
done
for tool in herdr jq; do
	command -v "$tool" >/dev/null || echo "install.sh: warning: $tool not found (herdr: needed by the daemon; jq: used by the example boards)"
done

echo "==> building shim (cargo)"
cargo build --release --manifest-path shim/Cargo.toml
echo "==> building boardd (odin)"
if [ "$(uname -s)" = "Darwin" ]; then
	odin build boardd -out:boardd/boardd
else
	odin build boardd -out:boardd/boardd -extra-linker-flags:"-lgcc_s -lm -lpthread -ldl"
fi
mkdir -p "$HOME/.config/boardkit/boards"
echo "built $root/boardd/boardd; put boards in ~/.config/boardkit/boards"

[ "$1" = "--no-service" ] && exit 0

case "$(uname -s)" in
Darwin)
	# launchd user agent (macOS)
	plist="$HOME/Library/LaunchAgents/com.boardkit.boardd.plist"
	mkdir -p "$(dirname "$plist")" "$HOME/Library/Logs"
	sed -e "s#@BOARDKIT@#$root#g" -e "s#@HOME@#$HOME#g" -e "s#@HOMEBREW@#$(brew --prefix 2>/dev/null || echo /opt/homebrew)#g" macos/com.boardkit.boardd.plist > "$plist"
	launchctl unload "$plist" 2>/dev/null || true
	launchctl load "$plist"
	echo "boardd agent: $(launchctl list | grep com.boardkit.boardd >/dev/null && echo loaded || echo failed) (logs: ~/Library/Logs/boardd.log)"
	echo "note: boardd draws into herdr; start herdr for panes to appear."
	;;
Linux)
	command -v systemctl >/dev/null || { echo "install.sh: no systemctl; run boardd/boardd inside herdr instead"; exit 0; }
	unit="$HOME/.config/systemd/user/boardd.service"
	mkdir -p "$(dirname "$unit")"
	sed "s#@BOARDKIT@#$root#" systemd/boardd.service > "$unit"
	systemctl --user daemon-reload
	systemctl --user enable --now boardd
	systemctl --user restart boardd # pick up a rebuilt binary
	echo "boardd service: $(systemctl --user is-active boardd) (logs: journalctl --user -u boardd -f)"
	;;
*)
	echo "install.sh: no service integration for $(uname -s); run boardd/boardd inside herdr"
	;;
esac
