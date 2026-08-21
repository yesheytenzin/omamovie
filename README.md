# Omarchy OmaMovie

> **Credit:** [MovieBox-TUI](https://github.com/mesamirh/MovieBox-Tui) by [mesamirh](https://github.com/mesamirh) — ported to Python backend (`bridge/python/`).

Quickshell panel for movies, shows & anime — search, pick season/episode and stream in `mpv`.

- **No Rust, no binary downloads** — pure Python, `~1.8M` clone (was `~231M` before history purge)
- **Instant** — dedicated streams process, E1 auto-selected, `≥2` chars for suggestions, recent-search chips, `Esc` to close/clear
- **Verified** — `py_compile` + crypto unit tests on `push/PR` only (no release artifacts)

## Install

```bash
omarchy plugin add https://github.com/yesheytenzin/omamovie.git --enable
```

Creates shim `$XDG_CACHE_HOME/omamovie/omamovie-bridge` → `bridge/python/__main__.py` and verifies `{"cmd":"ping"}`. Click **** in the bar to browse.

## Update / Remove

```bash
omarchy plugin update tenzin.omamovie
omarchy plugin remove tenzin.omamovie
```

## Backend

Python port of `bridge/src/main.rs` + `moviebox-tui` crates. `Panel.qml` unchanged — same CLI JSON contract.

| File | Role |
|---|---|
| `bridge/python/crypto.py` | HMAC-MD5 signing (`x-client-token`, `x-tr-signature`), sorted query, `x-client-info` |
| `bridge/python/client.py` | 7-host failover, `requests` or `urllib` fallback, token via `x-user` |
| `bridge/python/cache.py` | `~/.cache/moviebox-tui/` — 24h search/details, 2h streams, 1h homepage |
| `bridge/python/__main__.py` | `ping`/`search`/`suggest`/`details`/`resources`/`captions`/`homepage` + filtering/sorting |

Legacy Rust (`bridge/Cargo.toml`, `bridge/src/`) remains for reference, not built. `prebuilt/` removed; history purged via `filter-repo` (removed `bridge/target`, ~224M).

## Panel

- `Esc` closes from any view; clears search field when focused
- Episodes auto-populate on `openDetails`; `E1` selected, dedicated `streamsProc` for instant load
- Suggestions gated at `≥2` chars (220ms debounce, history instant)
- Recent searches `Flow` (max 10, deduped, click to re-search)
- Streams placeholder: `Loading streams for S1E1 …` / `No streams — tap again to retry` (retry `MouseArea`)
- Sub→dub fallback: `auto-switched to <lang> — N streams` when primary has no streams

## License

MIT
