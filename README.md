# Omarchy OmaMovie

> **Credit:** [MovieBox-TUI](https://github.com/mesamirh/MovieBox-Tui) by [mesamirh](https://github.com/mesamirh)

Quickshell panel for movies, shows & anime — search, pick season/episode and stream in `mpv`.

## Prerequisites

Fast install needs **`gh` or `cargo`** (either is enough) + `mpv`:

```bash
omarchy pkg add mpv
omarchy pkg add github-cli   # for fast attested download (<5s) — recommended
# or
omarchy pkg add rust         # for fallback source build (cargo --locked, ~2 min)
```

* `gh` — verifies SLSA provenance of the release tarball (`gh attestation verify`). If missing, installer falls back to `cargo` build.
* `cargo` — reproducible build from locked source (`bridge/rust-toolchain.toml` 1.90.0). If both missing, install fails (no SHA256-only).

Authenticate `gh` once: `gh auth login`

## Install

```bash
omarchy plugin add https://github.com/yesheytenzin/omamovie.git --enable
```

Downloads the attested `OmaMovie_Linux_$ARCH.tar.gz` and verifies `SHA256SUMS` + SLSA provenance fail-closed, or builds from source if needed. Click **** in the bar to browse.

## Update

```bash
omarchy plugin update tenzin.omamovie
```

## Remove

```bash
omarchy plugin remove tenzin.omamovie
```

## License

MIT
