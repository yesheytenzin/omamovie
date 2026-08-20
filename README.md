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

Add the plugin and download the prebuilt bridge:

```bash
omarchy plugin add https://github.com/yesheytenzin/omamovie.git --enable --yes
omarchy-shell shell rescanPlugins

# downloads the release for your CPU, verifies SHA256, installs to ~/.local/bin
~/.config/omarchy/plugins/tenzin.omamovie/omamovie-setup.sh
omarchy-shell shell rescanPlugins
```

Click the **video camera** icon in the bar: search, pick a title, choose a
stream (resolution / codec / size), Play. Series get a season + episode
picker; subtitles are downloaded automatically when available.

## Update

```bash
omarchy plugin update tenzin.omamovie --yes     # pull new plugin code
~/.config/omarchy/plugins/tenzin.omamovie/omamovie-setup.sh   # download new bridge
```

## Remove

```bash
omarchy plugin remove tenzin.omamovie --yes
rm -f ~/.local/bin/omamovie-bridge              # optional: drop the bridge
```

## How it works

```
BarWidget.qml ──► opens Panel.qml (Quickshell popup UI)
                      │
                      ▼  newline-JSON via CLI
              omamovie-bridge  (Rust, ~/.local/bin)
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
omamovie-bridge '{"cmd":"search","q":"dune","page":1}'
omamovie-bridge '{"cmd":"details","id":"<subjectId>"}'
omamovie-bridge '{"cmd":"resources","id":"<id>","season":1,"episode":2}'
omamovie-bridge '{"cmd":"captions","id":"<id>","rid":"<resourceId>"}'
omamovie-bridge '{"cmd":"poster","url":"https://..."}'   # cached file path
omamovie-bridge '{"cmd":"subfile","url":"https://...srt"}' # downloaded path
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
