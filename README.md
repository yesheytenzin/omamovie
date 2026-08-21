# Omarchy OmaMovie

> **Credit:** [MovieBox-TUI](https://github.com/mesamirh/MovieBox-Tui) by [mesamirh](https://github.com/mesamirh) — ported to Python backend (`bridge/python/`).

Quickshell panel for movies, shows & anime — search, pick season/episode and stream in `mpv`.

## Prerequisites

Needs **`python3` + `mpv`** (no `cargo` / `gh` required):

```bash
omarchy pkg add mpv
omarchy pkg add python   # provides python3.14 (or python3)
# optional for faster HTTP keep-alive:
# omarchy pkg add python-pip && pip install requests
# or: omarchy pkg add python-requests
```

The bridge is pure Python (`bridge/python/`). It uses stdlib `urllib` by default; if `requests` is installed it will use it for keep-alive. No binary download or SLSA attestation is needed — the source is directly audited.

Requires Python 3.10+. Verified on 3.14.

## Install

```bash
omarchy plugin add https://github.com/yesheytenzin/omamovie.git --enable
```

The setup script creates a shim at `.runtime/omamovie-bridge` that forwards to `bridge/python/__main__.py` and verifies with `{"cmd":"ping"}`. Click **** in the bar to browse.

## Backend

Python port of the original Rust bridge (`bridge/src/main.rs` + `moviebox-tui` crates). No compilation, no binary downloads.

- `bridge/python/crypto.py` — HMAC-MD5 request signing (`x-client-token`, `x-tr-signature`)
- `bridge/python/client.py` — host-pool failover, `requests` or `urllib` fallback
- `bridge/python/cache.py` — file cache at `~/.cache/moviebox-tui/` (24h search/details, 2h streams)
- `bridge/python/__main__.py` — CLI JSON bridge (`ping`, `search`, `suggest`, `details`, `resources`, `captions`, `homepage`, etc.) — same contract as the Rust binary (`Panel.qml` unchanged)

Legacy Rust sources remain in `bridge/` but are no longer built or required.

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
