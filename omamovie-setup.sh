#!/usr/bin/env bash
# Downloads the prebuilt bridge into this plugin's private runtime directory.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-$DIR/.runtime}"
BIN="omamovie-bridge"
VERSION="$(jq -er '.version' "$DIR/manifest.json")"
VERSION_FILE="$INSTALL_DIR/version"
REVISION_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/omamovie/plugin-revision"
RELEASE_BASE="${OMAMOVIE_RELEASE_BASE:-https://github.com/yesheytenzin/omamovie/releases/download/v$VERSION}"

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

record_plugin_revision() {
  local revision
  revision="$(git -C "$DIR" rev-parse HEAD 2>/dev/null || printf '%s' "$VERSION")"
  mkdir -p "$(dirname "$REVISION_FILE")"
  if [[ ! -f "$REVISION_FILE" || $(<"$REVISION_FILE") != "$revision" ]]; then
    printf '%s\n' "$revision" >"$REVISION_FILE.new"
    mv -f "$REVISION_FILE.new" "$REVISION_FILE"
  fi
}

LOCK_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/omamovie/setup.lock"
exec 9>"$LOCK_FILE"
flock -w 180 9 || { warn "another install is already running"; exit 0
}
# No explicit rescan - rely on omarchy plugin manager's rescan and file watcher (single reload)

if [[ -x "$INSTALL_DIR/$BIN" && -f "$VERSION_FILE" && $(<"$VERSION_FILE") == "$VERSION" ]]; then
  say "bridge $VERSION is already installed"
  record_plugin_revision
  # No rescan here - omarchy plugin add/update already did one, and file watcher will handle .runtime changes
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
ARCHIVE="OmaMovie_Linux_${ARCH}.tar.gz"

say "downloading $ARCHIVE ..."
# Download with progress for widget percentage (PROGRESS:NN to stdout, parsed by BarWidget)
if command -v stdbuf >/dev/null 2>&1; then
  # Use --progress-bar and translate carriage returns to newlines for parsing
  set +e
  curl -fL --retry 3 --progress-bar -o "$TMP/$ARCHIVE" "$RELEASE_BASE/$ARCHIVE" 2>&1 | stdbuf -oL tr '\r' '\n' | while IFS= read -r line; do
    if [[ "$line" =~ ([0-9]+)% ]]; then
      echo "PROGRESS:${BASH_REMATCH[1]}"
    fi
  done
  curl_status=${PIPESTATUS[0]}
  set -e
  if (( curl_status != 0 )); then
    fail "download failed (curl exit $curl_status)"
  fi
else
  curl -fsSL --retry 3 -o "$TMP/$ARCHIVE" "$RELEASE_BASE/$ARCHIVE" || fail "download failed"
fi
curl -fsSL --retry 3 -o "$TMP/SHA256SUMS" "$RELEASE_BASE/SHA256SUMS"
(cd "$TMP" && sha256sum -c SHA256SUMS --ignore-missing --quiet) ||
  fail "release checksum verification failed"

tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
[[ -x "$TMP/$BIN" ]] || fail "$BIN was not found in the release archive"
install -m 0755 "$TMP/$BIN" "$INSTALL_DIR/$BIN.new"
mv -f "$INSTALL_DIR/$BIN.new" "$INSTALL_DIR/$BIN"
printf '%s\n' "$VERSION" >"$VERSION_FILE.new"
mv -f "$VERSION_FILE.new" "$VERSION_FILE"
say "installed $INSTALL_DIR/$BIN"

if "$INSTALL_DIR/$BIN" '{"cmd":"ping"}' | grep -q '"ok":true'; then
  say "bridge OK"
else
  warn "bridge installed but did not respond to ping"
fi
record_plugin_revision
