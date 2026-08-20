#!/usr/bin/env bash
# Downloads the prebuilt OmaMovie bridge and installs it to ~/.local/bin.
set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
BIN="omamovie-bridge"
RELEASE_BASE="${OMAMOVIE_RELEASE_BASE:-https://github.com/yesheytenzin/omamovie/releases/latest/download}"

say()  { printf '\033[1;36m[omamovie]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[omamovie]\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31m[omamovie]\033[0m %s\n' "$*"; exit 1; }

command -v mpv >/dev/null 2>&1 || command -v vlc >/dev/null 2>&1 ||
  warn "no media player found - install one with: omarchy pkg add mpv"

case "$(uname -m)" in
  x86_64)        ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac

mkdir -p "$INSTALL_DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ARCHIVE="OmaMovie_Linux_${ARCH}.tar.gz"

say "downloading $ARCHIVE ..."
curl -fSL --retry 3 -o "$TMP/$ARCHIVE" "$RELEASE_BASE/$ARCHIVE"
curl -fSL --retry 3 -o "$TMP/SHA256SUMS" "$RELEASE_BASE/SHA256SUMS"
(cd "$TMP" && sha256sum -c SHA256SUMS --ignore-missing --quiet) ||
  fail "release checksum verification failed"

tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
[[ -x "$TMP/$BIN" ]] || fail "$BIN was not found in the release archive"
install -m 0755 "$TMP/$BIN" "$INSTALL_DIR/$BIN"
say "installed $INSTALL_DIR/$BIN"

if "$INSTALL_DIR/$BIN" '{"cmd":"ping"}' | grep -q '"ok":true'; then
  say "bridge OK - reload the plugin (omarchy-shell shell rescanPlugins) and click its bar icon"
else
  warn "bridge installed but did not respond to ping"
fi
