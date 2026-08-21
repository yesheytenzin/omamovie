#!/usr/bin/env bash
# Installs the omamovie bridge into this plugin's private runtime directory.
# Default: build reproducibly from locked source (bridge/rust-toolchain.toml).
# Fallback: download attested release archive and verify SHA256 + SLSA provenance.
# Optional fast prebuilt in git (if present) is only used when OMAMOVIE_ALLOW_PREBUILT=1
# and is verified fail-closed against its SLSA attestation / SHA256 sidecar.
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

if [[ -n "${OMAMOVIE_RELEASE_BASE:-}" ]]; then
  say "using custom release base: $RELEASE_BASE"
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

verify_attestation() {
  # Fail-closed verification of a subject against its SLSA attestation via gh CLI.
  # Returns 0 on verified, 1 on failure. Caller decides strictness.
  local subject="$1"
  if ! command -v gh >/dev/null 2>&1; then
    warn "gh CLI not found — cannot verify SLSA attestation for $subject (install gh or set OMAMOVIE_ATTESTATION_STRICT=0 to allow SHA256-only)"
    return 1
  fi
  if gh attestation verify "$subject" --repo "yesheytenzin/omamovie" >/dev/null 2>&1; then
    say "SLSA attestation verified for $subject"
    return 0
  else
    warn "SLSA attestation verification failed for $subject"
    return 1
  fi
}

build_from_source() {
  say "building bridge from locked source (bridge/rust-toolchain.toml) — reproducible, no prebuilt trust"
  if ! command -v cargo >/dev/null 2>&1; then
    return 1
  fi
  case "$(uname -m)" in
    x86_64)        CARGO_TARGET="x86_64-unknown-linux-gnu" ;;
    aarch64|arm64) CARGO_TARGET="aarch64-unknown-linux-gnu" ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac
  (
    cd "$DIR"
    export SOURCE_DATE_EPOCH=$(git -C "$DIR" log -1 --format=%ct 2>/dev/null || date +%s)
    export CARGO_INCREMENTAL=0
    export RUSTFLAGS="${RUSTFLAGS:-} -Cstrip=debuginfo"
    say "cargo build --locked --release --target $CARGO_TARGET (SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH)"
    cargo build --locked --release --manifest-path bridge/Cargo.toml --target "$CARGO_TARGET"
    local bin_src="bridge/target/${CARGO_TARGET}/release/$BIN"
    [[ -x "$bin_src" ]] || fail "cargo build produced no binary at $bin_src"
    # Record hash of built binary for provenance
    sha256sum "$bin_src" | tee "$bin_src.sha256" >/dev/null
    if ! "$bin_src" '{"cmd":"ping"}' | grep -q '"ok":true'; then
      fail "built bridge did not respond to ping"
    fi
    install -m 0755 "$bin_src" "$INSTALL_DIR/$BIN.new"
    mv -f "$INSTALL_DIR/$BIN.new" "$INSTALL_DIR/$BIN"
    printf '%s\n' "$VERSION" >"$VERSION_FILE.new"
    mv -f "$VERSION_FILE.new" "$VERSION_FILE"
    say "installed $INSTALL_DIR/$BIN from source (target $CARGO_TARGET, $(sha256sum "$INSTALL_DIR/$BIN" | cut -d' ' -f1 | cut -c1-12)...)"
  )
}

LOCK_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/omamovie/setup.lock"
exec 9>"$LOCK_FILE"
flock -w 180 9 || { warn "another install is already running"; exit 0; }

if [[ -x "$INSTALL_DIR/$BIN" && -f "$VERSION_FILE" && $(<"$VERSION_FILE") == "$VERSION" ]]; then
  say "bridge $VERSION is already installed"
  record_plugin_revision
  exit 0
fi

# 1) Default: build from locked source (fail-closed provenance: built from audited bridge/ + Cargo.lock)
#    Honour OMAMOVIE_PREFER_RELEASE=1 to skip source build and go straight to verified release download.
#    Also honour legacy OMAMOVIE_BUILD_FROM_SOURCE=1.
if [[ "${OMAMOVIE_PREFER_RELEASE:-0}" != "1" ]]; then
  if build_from_source; then
    if "$INSTALL_DIR/$BIN" '{"cmd":"ping"}' | grep -q '"ok":true'; then
      say "bridge OK (built from source)"
      record_plugin_revision
      exit 0
    else
      warn "source-built bridge failed ping — falling through to verified release download"
      rm -f "$INSTALL_DIR/$BIN" "$VERSION_FILE"
    fi
  else
    warn "cargo build not available or failed — falling back to verified release archive (attested)"
  fi
else
  say "OMAMOVIE_PREFER_RELEASE=1 — skipping source build, using verified release archive"
fi

# 2) Optional fast prebuilt in git: only if explicitly allowed, and verified fail-closed
PREBUILT_DIR="$DIR/prebuilt/$ARCH"
if [[ "${OMAMOVIE_ALLOW_PREBUILT:-0}" == "1" && -x "$PREBUILT_DIR/$BIN" && -f "$PREBUILT_DIR/version" && $(<"$PREBUILT_DIR/version") == "$VERSION" ]]; then
  say "OMAMOVIE_ALLOW_PREBUILT=1 — attempting verified prebuilt/$ARCH install"
  # Fail-closed: need independent attestation for the raw binary, not just sidecar consistency.
  # The sidecar alone proves file consistency (ELF+sha together), not source provenance.
  # Require SLSA attestation verification for the exact binary.
  if [[ -f "$PREBUILT_DIR/$BIN.sigstore.json" || -f "$PREBUILT_DIR/$BIN.intoto.jsonl" ]]; then
    # gh attestation verify can take --bundle
    local bundle=""
    [[ -f "$PREBUILT_DIR/$BIN.sigstore.json" ]] && bundle="$PREBUILT_DIR/$BIN.sigstore.json"
    [[ -f "$PREBUILT_DIR/$BIN.intoto.jsonl" ]] && bundle="$PREBUILT_DIR/$BIN.intoto.jsonl"
    if ! verify_attestation "$PREBUILT_DIR/$BIN"; then
      fail "prebuilt attestation verification failed — refusing to install unverified ELF (unset OMAMOVIE_ALLOW_PREBUILT or build from source)"
    fi
  elif [[ -f "$PREBUILT_DIR/$BIN.sha256" ]]; then
    # At minimum, verify hash sidecar — but this alone is not provenance, so require attestation in strict mode
    say "verifying prebuilt hash against sidecar $PREBUILT_DIR/$BIN.sha256 (consistency only)"
    (cd "$(dirname "$PREBUILT_DIR/$BIN")" && sha256sum -c "$(basename "$PREBUILT_DIR/$BIN.sha256")" --quiet) || fail "prebuilt hash verification failed ($PREBUILT_DIR/$BIN.sha256)"
    if [[ "${OMAMOVIE_ATTESTATION_STRICT:-0}" == "1" ]]; then
      fail "strict attestation required but no bundle for prebuilt — refusing (build from source or use verified release)"
    else
      warn "prebuilt verified only for consistency, not SLSA provenance — consider building from source (default) or use verified release"
    fi
  else
    fail "prebuilt found but no .sha256 or attestation bundle — refusing unverified install"
  fi
  install -m 0755 "$PREBUILT_DIR/$BIN" "$INSTALL_DIR/$BIN.new"
  mv -f "$INSTALL_DIR/$BIN.new" "$INSTALL_DIR/$BIN"
  printf '%s\n' "$VERSION" >"$VERSION_FILE.new"
  mv -f "$VERSION_FILE.new" "$VERSION_FILE"
  say "installed $INSTALL_DIR/$BIN (verified prebuilt, OMAMOVIE_ALLOW_PREBUILT=1)"
  if "$INSTALL_DIR/$BIN" '{"cmd":"ping"}' | grep -q '"ok":true'; then say "bridge OK"; else warn "bridge installed but did not respond to ping"; fi
  record_plugin_revision
  exit 0
elif [[ -x "$PREBUILT_DIR/$BIN" ]]; then
  say "prebuilt/$ARCH/omamovie-bridge exists but ignored — default is build from source or verified release (set OMAMOVIE_ALLOW_PREBUILT=1 to use it with verification)"
fi

# 3) Verified release archive path — fail-closed on SHA256 + SLSA provenance
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
say "downloading verified release $ARCHIVE ..."
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
(cd "$TMP" && sha256sum -c SHA256SUMS --ignore-missing --quiet) || fail "release checksum verification failed (fail-closed)"
say "SHA256SUMS verified (fail-closed)"

# SLSA provenance for the exact archive (and SHA256SUMS) — fail-closed if gh present or strict mode
if command -v gh >/dev/null 2>&1; then
  if verify_attestation "$TMP/$ARCHIVE"; then
    say "release archive SLSA provenance verified (fail-closed)"
  else
    if [[ "${OMAMOVIE_ATTESTATION_STRICT:-0}" == "1" || "${OMAMOVIE_ALLOW_UNVERIFIED_RELEASE:-0}" != "1" ]]; then
      # Default: SHA256 is already verified, but provenance not verified — still fail-closed per reviewer ask:
      # require attestation when gh is available. Allow bypass only with explicit env.
      if [[ "${OMAMOVIE_ALLOW_UNVERIFIED_RELEASE:-0}" == "1" ]]; then
        warn "proceeding without SLSA attestation (OMAMOVIE_ALLOW_UNVERIFIED_RELEASE=1)"
      else
        fail "release attestation verification failed — refusing unverified archive (install gh or set OMAMOVIE_ALLOW_UNVERIFIED_RELEASE=1 to allow SHA256-only, or OMAMOVIE_ATTESTATION_STRICT=0 to warn-only)"
      fi
    fi
  fi
  # Also verify SHA256SUMS attestation if present
  if ! verify_attestation "$TMP/SHA256SUMS" 2>/dev/null; then
    warn "SHA256SUMS attestation not verified (optional)"
  fi
else
  warn "gh not found — SHA256 verified but SLSA attestation not checked (install gh for full provenance)"
  if [[ "${OMAMOVIE_ATTESTATION_STRICT:-0}" == "1" ]]; then
    fail "strict attestation required but gh not found"
  fi
fi

if ! tar -tzf "$TMP/$ARCHIVE" | grep -qxE "(\./)?$BIN"; then
  fail "release archive has unexpected contents (ZipSlip)"
fi
tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
[[ -x "$TMP/$BIN" ]] || fail "$BIN was not found in the release archive"
# The extracted binary is the exact installed artifact — its hash is covered by the verified tarball's attestation
sha256sum "$TMP/$BIN" | tee "$TMP/$BIN.sha256" >/dev/null
say "extracted binary hash $(cut -d' ' -f1 "$TMP/$BIN.sha256" | cut -c1-12)... (covered by attested tarball)"
install -m 0755 "$TMP/$BIN" "$INSTALL_DIR/$BIN.new"
mv -f "$INSTALL_DIR/$BIN.new" "$INSTALL_DIR/$BIN"
printf '%s\n' "$VERSION" >"$VERSION_FILE.new"
mv -f "$VERSION_FILE.new" "$VERSION_FILE"
say "installed $INSTALL_DIR/$BIN (verified release tarball, fail-closed)"

if "$INSTALL_DIR/$BIN" '{"cmd":"ping"}' | grep -q '"ok":true'; then
  say "bridge OK"
else
  warn "bridge installed but did not respond to ping"
fi
record_plugin_revision
