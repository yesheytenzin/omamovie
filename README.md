# Omarchy OmaMovie

One-click launcher for [MovieBox-TUI](https://github.com/mesamirh/MovieBox-Tui)
from your Omarchy bar: a lightweight terminal client that searches, streams
and downloads movies, TV shows, anime and live TV in `mpv`/`VLC` — no browser
needed.

The plugin is just a launcher + installer. It hosts no content and contains
no scraping code; all functionality comes from MovieBox-TUI itself.

## Install

```bash
omarchy plugin add https://github.com/yesheytenzin/omamovie.git --enable --yes
# or local path while developing
omarchy plugin add /home/tenzin/plugins/omamovie --enable --yes
omarchy-shell shell rescanPlugins
```

The widget appears in the **right** section. Move it:

```bash
omarchy bar move tenzin.omamovie --section left
```

First click installs `moviebox-tui` to `~/.local/bin` (official GitHub release,
checksum-verified when `SHA256SUMS` is published), then opens it. A media
player is required for playback (`mpv` recommended):

```bash
omarchy pkg add mpv
```

## Use

- Click the **video camera** icon to open MovieBox-TUI in your default terminal
  (via `xdg-terminal-exec`).
- Press `?` inside the app for the full key map.
- The terminal opens with `--app-id=moviebox-tui`, so a Hyprland rule can target
  it, e.g. in `~/.config/hypr/hyprland.lua`:

  ```lua
  o.window("class:moviebox-tui", { size = "60% 70%", float = true })
  ```

- Change the bar glyph by editing `text` in `BarWidget.qml` (it is a Nerd Font
  glyph, `\uf03d`).

## Update

```bash
omarchy plugin update tenzin.omamovie --yes   # pull latest plugin code
# then refresh the moviebox binary itself:
~/.config/omarchy/plugins/tenzin.omamovie/moviebox-setup.sh
```

## Uninstall

```bash
omarchy plugin remove tenzin.omamovie --yes
rm -f ~/.local/bin/moviebox-tui   # optional: also drop the binary
```

The bar icon is removed with the plugin; downloads, config and `~/.local/bin`
are left untouched by the plugin removal itself.

## Files

```
moviebox-tui/
  manifest.json        # bar-widget metadata
  BarWidget.qml        # bar icon; checks for the binary, launches the TUI
  moviebox-launch.sh   # install-if-missing, then xdg-terminal-exec
  moviebox-setup.sh    # downloads the official release to ~/.local/bin
  README.md
  LICENSE
```

## Legal note

MovieBox-TUI streams and downloads third-party content. The plugin does not
host, store, or redistribute anything itself — users are responsible for
complying with the laws of their country, as per the upstream project's own
disclaimer.

## License

MIT — see `LICENSE`.
