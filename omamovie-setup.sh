#!/usr/bin/env bash
# Installs the omamovie bridge into this plugin's private runtime directory.
# Fast path: use bundled prebuilt/$ARCH/omamovie-bridge if present and verified.
# Reproducible path: OMAMOVIE_BUILD_FROM_SOURCE=1 forces local cargo build.
# Fallback: download release tarball and verify SHA256SUMS + attestable provenance.
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

# Hardening: log custom release base if overridden (env poisoning otherwise allows attacker-controlled binary + checksum)
if [[ -n "${OMAMOVIE_RELEASE_BASE:-}" ]]; then
  say "using custom release base: $RELEASE_BASE"
fi

# Optional source-build for auditors / reproducible verification:
#   OMAMOVIE_BUILD_FROM_SOURCE=1 omarchy plugin add ...
if [[ "${OMAMOVIE_BUILD_FROM_SOURCE:-0}" == "1" ]]; then
  say "OMAMOVIE_BUILD_FROM_SOURCE=1 — building bridge from source (pinned toolchain)"
  if ! command -v cargo >/dev/null 2>&1; then
    fail "cargo not found — install Rust (bridge/rust-toolchain.toml pins 1.85.0) or unset OMAMOVIE_BUILD_FROM_SOURCE"
  fi
  case "$(uname -m)" in
    x86_64)        CARGO_TARGET="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) CARGO_TARGET="aarch64-unknown-linux-gnu" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac
  mkdir -p "$INSTALL_DIR"
  (
    cd "$DIR"
    # Reproducible flags mirrored from CI (release.yml)
    export SOURCE_DATE_EPOCH=$(git -C "$DIR" log -1 --format=%ct 2>/dev/null || date +%s)
    export CARGO_INCREMENTAL=0
    export RUSTFLAGS="${RUSTFLAGS:-} -Cstrip=debuginfo"
    cargo build --locked --release --manifest-path bridge/Cargo.toml --target "$CARGO_TARGET"
    BIN_SRC="bridge/target/${CARGO_TARGET}/release/$BIN"
    [[ -x "$BIN_SRC" ]] || fail "cargo build produced no binary at $BIN_SRC"
    # Verify built binary responds to ping before installing
    if ! "$BIN_SRC" '{"cmd":"ping"}' | grep -q '"ok":true'; then
      fail "built bridge did not respond to ping"
    fi
    install -m 0755 "$BIN_SRC" "$INSTALL_DIR/$BIN.new"
    mv -f "$INSTALL_DIR/$BIN.new" "$INSTALL_DIR/$BIN"
    printf '%s\n' "$VERSION" >"$VERSION_FILE.new"
    mv -f "$VERSION_FILE.new" "$VERSION_FILE"
    say "installed $INSTALL_DIR/$BIN from source (target $CARGO_TARGET)"
  )
  if "$INSTALL_DIR/$BIN" '{"cmd":"ping"}' | grep -q '"ok":true'; then
    say "bridge OK"
  else
    warn "bridge installed but did not respond to ping"
  fi
  mkdir -p "$(dirname "$REVISION_FILE")"
  printf '%s\n' "$(git -C "$DIR" rev-parse HEAD 2>/dev/null || printf '%s' "$VERSION")" >"$REVISION_FILE.new" 2>/dev/null || true
  mv -f "$REVISION_FILE.new" "$REVISION_FILE" 2>/dev/null || true
  exit 0
fi

command -v mpv >/dev/null 2>&1 || command -v vlc >/dev/null 2>&1 ||
  warn "no media player found - install one with: omarchy pkg add mpv"

case "$(uname -m)" in
  x86_64)        ARCH="x64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) fail "unsupported architecture: $(uname -m)" ;;
esac
ARCHIVE="OmaMovie_Linux_${ARCH}.tar.gz"

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

verify_prebuilt_hash() {
  # Verify bundled prebuilt hash against committed sidecar .sha256 if present,
  # plus optional release attestation via gh CLI if available.
  local prebuilt_bin="$1"
  local sha_file="$2"
  if [[ -f "$sha_file" ]]; then
    say "verifying prebuilt hash against $sha_file"
    (cd "$(dirname "$prebuilt_bin")" && sha256sum -c "$(basename "$sha_file")" --quiet) || fail "prebuilt hash verification failed ($sha_file)"
    say "prebuilt hash OK"
  else
    warn "no sidecar $sha_file — skipping hash check (consider shipping .sha256)"
  fi
  # Optional SLSA attestation verify if gh CLI and attestation are available (best-effort, does not block install)
  if command -v gh >/dev/null 2>&1 && [[ -n "${OMAMOVIE_VERIFY_ATTESTATION:-}" ]]; then
    if gh attestation verify "$prebuilt_bin" --repo "yesheytenzin/omamovie" >/dev/null 2>&1; then
      say "attestation verified via gh"
    else
      warn "attestation verification skipped/failed (install continues; set OMAMOVIE_VERIFY_ATTESTATION=1 to enforce)"
      if [[ "${OMAMOVIE_ATTESTATION_STRICT:-0}" == "1" ]]; then
        fail "attestation verification failed in strict mode"
      fi
    fi
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

PREBUILT_DIR="$DIR/prebuilt/$ARCH"
if [[ -x "$PREBUILT_DIR/$BIN" && -f "$PREBUILT_DIR/version" && $(<"$PREBUILT_DIR/version") == "$VERSION" ]]; then
  say "bridge $VERSION found in git (prebuilt/$ARCH) — verifying before install"
  # Reproducible + provenance: verify bundled binary hash before executing it
  verify_prebuilt_hash "$PREBUILT_DIR/$BIN" "$PREBUILT_DIR/$BIN.sha256"
  install -m 0755 "$PREBUILT_DIR/$BIN" "$INSTALL_DIR/$BIN.new"
  mv -f "$INSTALL_DIR/$BIN.new" "$INSTALL_DIR/$BIN"
  printf '%s\n' "$VERSION" >"$VERSION_FILE.new"
  mv -f "$VERSION_FILE.new" "$VERSION_FILE"
  say "installed $INSTALL_DIR/$BIN (verified prebuilt)"
else
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  say "prebuilt bridge not found - downloading $ARCHIVE ..."
  # The release is CI-built after the v$VERSION tag is pushed; wait for it
  # instead of failing on a transient 404 (the race the setup used to hit).
  attempts=0
  while ! curl -fsI --max-time 10 "$RELEASE_BASE/$ARCHIVE" >/dev/null 2>&1 \
    || ! curl -fsI --max-time 10 "$RELEASE_BASE/SHA256SUMS" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    (( attempts <= 20 )) || fail "release v$VERSION is not published yet; try again later"
    say "release v$VERSION still building - retry $attempts/20"
    sleep 5
  done
  curl -fsSL --retry 3 -o "$TMP/$ARCHIVE" "$RELEASE_BASE/$ARCHIVE" || fail "download failed"
  curl -fsSL --retry 3 -o "$TMP/SHA256SUMS" "$RELEASE_BASE/SHA256SUMS"
  (cd "$TMP" && sha256sum -c SHA256SUMS --ignore-missing --quiet) ||
    fail "release checksum verification failed"
  # Optional strict attestation verify if requested
  if [[ "${OMAMOVIE_VERIFY_ATTESTATION:-0}" == "1" ]] && command -v gh >/dev/null 2>&1; then
    if ! gh attestation verify "$TMP/$ARCHIVE" --repo "yesheytenzin/omamovie" >/dev/null 2>&1; then
      warn "gh attestation verify failed for release archive"
      [[ "${OMAMOVIE_ATTESTATION_STRICT:-0}" != "1" ]] || fail "attestation verification failed in strict mode"
    else
      say "release attestation verified"
    fi
  fi
  # Mitigate tar traversal (ZipSlip): archive must contain only the expected binary
  if ! tar -tzf "$TMP/$ARCHIVE" | grep -qxE "(\./)?$BIN"; then
    fail "release archive has unexpected contents"
  fi

  tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
  [[ -x "$TMP/$BIN" ]] || fail "$BIN was not found in the release archive"
  install -m 0755 "$TMP/$BIN" "$INSTALL_DIR/$BIN.new"
  mv -f "$INSTALL_DIR/$BIN.new" "$INSTALL_DIR/$BIN"
  printf '%s\n' "$VERSION" >"$VERSION_FILE.new"
  mv -f "$VERSION_FILE.new" "$VERSION_FILE"
  say "installed $INSTALL_DIR/$BIN (verified release tarball)"
fi

if "$INSTALL_DIR/$BIN" '{"cmd":"ping"}' | grep -q '"ok":true'; then
  say "bridge OK"
else
  warn "bridge installed but did not respond to ping"
fi
record_plugin_revision
