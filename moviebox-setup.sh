#!/usr/bin/env bash
# Install (or update) MovieBox-TUI from the official GitHub release.
# Writes only to ~/.local/bin. Safe to re-run.
set -euo pipefail

BIN_NAME="moviebox-tui"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
RELEASE_BASE="https://github.com/mesamirh/MovieBox-Tui/releases/latest/download"

say()  { printf '\033[1;36m[moviebox]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[moviebox]\033[0m %s\n' "$*"; }

case "$(uname -m)" in
  x86_64)             ARCH="x64" ;;
  aarch64|arm64)      ARCH="arm64" ;;
  *) warn "unsupported architecture: $(uname -m)"; exit 1 ;;
esac

PLAYER=""
for p in mpv vlc iina; do
  if command -v "$p" >/dev/null 2>&1; then PLAYER="$p"; break; fi
done
if [[ -z "$PLAYER" ]]; then
  warn "no media player found \u2014 install one with: omarchy pkg add mpv"
fi

mkdir -p "$INSTALL_DIR"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TARBALL="MovieBox_Linux_${ARCH}.tar.gz"

say "downloading $TARBALL from latest release \u2026"
if ! curl -fSL --retry 3 -o "$TMP/$TARBALL" "$RELEASE_BASE/$TARBALL"; then
  warn "download failed \u2014 falling back to cargo install"
  cargo install moviebox-tui --locked --root "$INSTALL_DIR"
  "$INSTALL_DIR/$BIN_NAME" >/dev/null 2>&1 || true
  say "installed $BIN_NAME via cargo"
  exit 0
fi

if curl -fsSL --retry 2 -o "$TMP/SHA256SUMS" "$RELEASE_BASE/SHA256SUMS" 2>/dev/null; then
  (cd "$TMP" && sha256sum -c SHA256SUMS --ignore-missing --quiet)
  say "checksum verified"
else
  warn "SHA256SUMS not published \u2014 skipping integrity check"
fi

tar -xzf "$TMP/$TARBALL" -C "$TMP"
BIN="$(find "$TMP" -maxdepth 3 -type f -name moviebox-tui -print -quit)"
if [[ -z "$BIN" ]]; then
  warn "binary not found inside archive"
  exit 1
fi

install -m 0755 "$BIN" "$INSTALL_DIR/$BIN_NAME"
say "installed $INSTALL_DIR/$BIN_NAME"

if [[ -n "$PLAYER" ]]; then
  say "playback will use: $PLAYER"
else
  warn "install a player first: omarchy pkg add mpv"
fi
