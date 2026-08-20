#!/usr/bin/env bash
# Launches MovieBox-TUI in the default terminal, installing it first if needed.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v moviebox-tui >/dev/null 2>&1; then
  if ! "$DIR/moviebox-setup.sh"; then
    if command -v notify-send >/dev/null 2>&1; then
      notify-send -a moviebox "MovieBox-TUI install failed" \
        "Run ~/.config/omarchy/plugins/tenzin.moviebox-tui/moviebox-setup.sh in a terminal for details."
    fi
    exit 1
  fi
fi

export PATH="$HOME/.local/bin:$PATH"
exec xdg-terminal-exec --app-id=moviebox-tui moviebox-tui
