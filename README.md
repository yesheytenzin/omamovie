# Omarchy OmaMovie

Your own Omarchy-native UI for movies, TV shows and anime — no terminal needed.

Where the old version just launched a third-party TUI, **OmaMovie 1.1 is a
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

That single command clones the plugin, enables its bar widget, downloads the
matching prebuilt bridge, verifies `SHA256SUMS`, and stores it privately under
`~/.config/omarchy/plugins/tenzin.omamovie/.runtime/`. Click the bar icon after
the brief first-run download finishes.

Click the **video camera** icon in the bar: search, pick a title, choose a
stream (resolution / codec / size), Play. Series get a season + episode
picker; subtitles are downloaded automatically when available.

## Update

```bash
omarchy plugin update tenzin.omamovie
```

The shell reloads the updated widget. If `manifest.json` has a new version,
the matching release bridge is downloaded automatically.

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
  omamovie-setup.sh      # downloads + verifies the release bridge
  bridge/
    Cargo.toml           # pins moviebox-tui (rev 90acb82c)
    src/main.rs          # JSON bridge over the upstream engine
  README.md  LICENSE
```

Bridge binaries are built once by GitHub Actions for x86_64 and arm64 whenever
a `v*` tag is pushed. They are stripped, compressed, published with
`SHA256SUMS`, and reused by every installation; users do not need Rust or the
large Cargo build directory.

## Legal note

OmaMovie itself hosts nothing. All content access goes through the
MovieBox-TUI engine, which per its own disclaimer streams publicly
available content — users are responsible for complying with the laws of
their country.

## License

MIT — see `LICENSE`.
