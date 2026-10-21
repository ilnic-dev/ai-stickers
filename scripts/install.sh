#!/bin/bash
# Builds "AI Stickers.app", installs it into /Applications and starts it.
# On first start it asks whether to launch at login (the menu bar menu changes that later).
set -euo pipefail
cd "$(dirname "$0")/.."

app="$(scripts/build-app.sh)"

# Stop the installed copy only (a `swift run` dev copy has the same process name) and wait,
# or `open` below could hand off to the dying process.
running="AI Stickers.app/Contents/MacOS/AiStickers"
pkill -f "$running" || true
for _ in {1..50}; do pgrep -f "$running" >/dev/null || break; sleep 0.2; done
pkill -9 -f "$running" || true  # still alive after 10 s

dest="/Applications/AI Stickers.app"
[ -d "$dest" ] && mv "$dest" "$(mktemp -d)/"  # replace, don't merge
ditto "$app" "$dest"
open "$dest"
echo "Installed: $dest"
