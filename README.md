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

That single command clones the plugin (bridge binary already included in git for fast install), enables its bar widget, installs the
matching prebuilt bridge, verifies its `prebuilt/$ARCH/omamovie-bridge.sha256` sidecar and release `SHA256SUMS` (plus optional SLSA attestation via `gh attestation verify`), and stores it privately under
`~/.config/omarchy/plugins/tenzin.omamovie/.runtime/`. The Omarchy shell
restarts automatically as soon as installation finishes. Click the bar icon;
if you click during the brief first-run install, the panel opens by itself
once installation completes.

For auditors: set `OMAMOVIE_BUILD_FROM_SOURCE=1` to force a local reproducible `cargo build --frozen` from `bridge/` (pinned `bridge/rust-toolchain.toml` `1.85.0`) instead of using the prebuilt ELF. Strict attestation mode is `OMAMOVIE_VERIFY_ATTESTATION=1 OMAMOVIE_ATTESTATION_STRICT=1` (requires `gh` CLI).

Click the **movie** icon in the bar (󰨂): search, pick a title, choose a
stream (resolution / codec / size), Play. Series get a season + episode
picker; subtitles are downloaded automatically when available.

## Update

```bash
omarchy plugin update tenzin.omamovie
```

The Omarchy shell restarts automatically after each actual update. If
`manifest.json` has a new version, the matching prebuilt bridge ships in git (`prebuilt/`); a release download is kept as fallback
automatically.

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
  omamovie-setup.sh      # installs prebuilt bridge; release download as fallback; verifies .sha256 + SLSA
  bridge/
    Cargo.toml           # pins moviebox-tui (rev 90acb82c)
    rust-toolchain.toml  # pins Rust 1.85.0 for reproducible local/CI builds
    src/main.rs          # JSON bridge over the upstream engine
  prebuilt/x64|arm64/    # stripped ELFs + .sha256 sidecars committed by CI
  README.md  LICENSE
```

Bridge binaries are built once by GitHub Actions for x86_64 and arm64 whenever
a `v*` tag is pushed. They are built reproducibly (`bridge/rust-toolchain.toml` `1.85.0`, `SOURCE_DATE_EPOCH`, `CARGO_INCREMENTAL=0`, `cargo --frozen --locked`), stripped, compressed with reproducible `tar --sort-name --mtime`, published with `SHA256SUMS` and SLSA provenance (`actions/attest-build-provenance`), and committed to `prebuilt/` with `.sha256` sidecars. Users do not need Rust by default; set `OMAMOVIE_BUILD_FROM_SOURCE=1` for a fully local build.

### Reproducible verification

```bash
# Pin toolchain matches CI
cat bridge/rust-toolchain.toml
# Rebuild locally and compare to prebuilt
cargo build --frozen --locked --release --manifest-path bridge/Cargo.toml --target x86_64-unknown-linux-gnu
sha256sum bridge/target/x86_64-unknown-linux-gnu/release/omamovie-bridge
cat prebuilt/x64/omamovie-bridge.sha256
# Or verify release attestation (requires gh CLI)
gh attestation verify prebuilt/x64/omamovie-bridge --repo yesheytenzin/omamovie
gh attestation verify OmaMovie_Linux_x64.tar.gz --repo yesheytenzin/omamovie
```

## Legal note

OmaMovie itself hosts nothing. All content access goes through the
MovieBox-TUI engine, which per its own disclaimer streams publicly
available content — users are responsible for complying with the laws of
their country.

## License

MIT — see `LICENSE`.
