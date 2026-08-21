# Omarchy OmaMovie

> **Credit:** Powered by [MovieBox-TUI](https://github.com/mesamirh/MovieBox-Tui) by [mesamirh](https://github.com/mesamirh) — all fetching via its engine, no scraping in this plugin.

Your own Omarchy-native UI for movies, TV shows and anime — no terminal needed.

Where the old version just launched a third-party TUI, **OmaMovie 1.5 is a
custom Quickshell panel** (search, poster grid, details, season/episode
picker, stream picker, subtitles) that plays in `mpv`. All fetching is done
by a small Rust bridge that links the
[MovieBox-TUI](https://github.com/mesamirh/MovieBox-Tui) engine as a library
— the same public engine the upstream project uses; the plugin UI itself
contains no scraping code.

## Install

Prerequisite:

```bash
omarchy pkg add mpv
```

Add and enable the plugin:

```bash
omarchy plugin add https://github.com/yesheytenzin/omamovie.git --enable
```

That single command clones the plugin, enables its bar widget, and installs the bridge **fast by default** — it downloads the attested release tarball `OmaMovie_Linux_$ARCH.tar.gz` and verifies `SHA256SUMS` **and** SLSA provenance (`actions/attest-build-provenance` pinned, `gh attestation verify`) **fail-closed** before extracting to `~/.config/omarchy/plugins/tenzin.omamovie/.runtime/` (`<5s`). If the release is unavailable or verification fails, it falls back to a reproducible local build from locked source (`bridge/rust-toolchain.toml` `1.90.0`, `cargo --locked`, `SOURCE_DATE_EPOCH`, `Cargo.lock` pinned `moviebox-tui@90acb82c`). No bundled ELF is executed without independent verification. The Omarchy shell restarts automatically; if you click during the brief download/build, the panel opens once ready.

For auditors or offline: `OMAMOVIE_BUILD_FROM_SOURCE=1` forces a local reproducible build instead of the fast verified download. Legacy `OMAMOVIE_PREFER_SOURCE=1` also prioritizes source. Bundled `prebuilt/` ELFs from older releases are ignored unless you explicitly `OMAMOVIE_ALLOW_PREBUILT=1` (then still verified against its SLSA bundle, fail-closed).

Click the **movie** icon in the bar (󰨂): search, pick a title, choose a
stream (resolution / codec / size), Play. Series get a season + episode
picker; subtitles are downloaded automatically when available.

## Update

```bash
omarchy plugin update tenzin.omamovie
```

The Omarchy shell restarts automatically after each actual update. If
`manifest.json` has a new version, the new attested release tarball is downloaded fast and verified fail-closed (fallback: rebuilt from source).

## Remove

```bash
omarchy plugin remove tenzin.omamovie
```

The private `.runtime/` directory and bridge are removed with the plugin.

## How it works

```
BarWidget.qml ──► opens Panel.qml (Quickshell popup UI)
                      │
                      ▼  newline-JSON via CLI
              omamovie-bridge  (Rust, plugin .runtime/)
                      │  links moviebox-tui crate (pinned git rev)
                      ▼  search / suggest / details / resources /
                         captions / subfile / poster (cached)
                    mpv ⏴ stream URL (+ subtitles)
```

The bridge is a stateless one-shot CLI: every panel action spawns it,
passes a JSON request and reads one JSON line back. Posters are cached in
`~/.cache/omamovie/posters/`.

### Bridge commands

```bash
B=~/.config/omarchy/plugins/tenzin.omamovie/.runtime/omamovie-bridge
$B '{"cmd":"search","q":"dune","page":1}'
$B '{"cmd":"details","id":"<subjectId>"}'
$B '{"cmd":"resources","id":"<id>","season":1,"episode":2}'
$B '{"cmd":"captions","id":"<id>","rid":"<resourceId>"}'
$B '{"cmd":"poster","url":"https://..."}'
$B '{"cmd":"subfile","url":"https://...srt"}'
```

## Files

```
omamovie/
  manifest.json          # bar-widget metadata (id tenzin.omamovie)
  BarWidget.qml          # bar icon -> panel
  Panel.qml              # the OmaMovie UI (search/grid/details/play)
  omamovie-setup.sh      # default fast attested download; fallback builds from locked source (both fail-closed)
  bridge/
    Cargo.toml           # pins moviebox-tui (rev 90acb82c)
    Cargo.lock           # fully locked deps
    rust-toolchain.toml  # 1.90.0 for reproducible local/CI builds
    src/main.rs          # JSON bridge over the upstream engine
  .github/workflows/release.yml # pinned action SHAs, SLSA attest of raw binary + tarball
  README.md  LICENSE
```

Bridge binaries are built reproducibly in CI (`bridge/rust-toolchain.toml` `1.90.0`, `SOURCE_DATE_EPOCH`, `CARGO_INCREMENTAL=0`, `cargo --locked`, `RUSTFLAGS=-Cstrip=debuginfo`, `tar --sort=name --mtime --owner=0`) for `x86_64`+`aarch64` on each `v*` tag, and published as `OmaMovie_Linux_*.tar.gz` + `SHA256SUMS` with SLSA provenance (`actions/attest-build-provenance` pinned to `e8998f9`, `id-token`/`attestations: write` least-privilege). The default install **downloads the attested tarball fast and verifies it fail-closed** before extracting — the exact installed binary is thus bound to the reviewed source revision; if unavailable, it falls back to a reproducible local `cargo --locked` build. No bundled `prebuilt/` ELF is trusted by default.

### Reproducible verification

```bash
cat bridge/rust-toolchain.toml  # 1.90.0
cargo build --locked --release --manifest-path bridge/Cargo.toml --target x86_64-unknown-linux-gnu
sha256sum bridge/target/x86_64-unknown-linux-gnu/release/omamovie-bridge  # compare to attested binary
# Verify a release artifact’s provenance (requires gh CLI)
gh attestation verify OmaMovie_Linux_x64.tar.gz --repo yesheytenzin/omamovie
gh attestation verify SHA256SUMS --repo yesheytenzin/omamovie
# Strict mode (fail if gh missing or attestation fails):
# OMAMOVIE_ATTESTATION_STRICT=1 omamovie-setup.sh
```

## Legal note

OmaMovie itself hosts nothing. All content access goes through the
MovieBox-TUI engine, which per its own disclaimer streams publicly
available content — users are responsible for complying with the laws of
their country.

## License

MIT — see `LICENSE`.
