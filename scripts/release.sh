#!/bin/bash
# Publishes a GitHub release with a ready-to-use "AI Stickers.app".
# Usage: scripts/release.sh 1.0.0   (run on an up-to-date, clean main)
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:?usage: scripts/release.sh <version>}"
tag="v$version"

[ "$(git branch --show-current)" = main ] || { echo "release from main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree is not clean" >&2; exit 1; }
git fetch -q origin
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not in sync with origin" >&2; exit 1; }

swift build && swift test >&2

app="$(scripts/build-app.sh "$version")"
zip="$(mktemp -d)/AI-Stickers-$version.zip"
ditto -c -k --keepParent "$app" "$zip"  # ditto keeps the bundle's signature and attributes

notes="$(mktemp)"
cat > "$notes" <<EOF
## Install

1. Download **AI-Stickers-$version.zip** below, unzip it and move **AI Stickers.app** to Applications.
2. Open it. macOS stops the first launch because the app isn't notarized: open **System Settings → Privacy & Security** and click **Open Anyway** (or run \`xattr -dr com.apple.quarantine "/Applications/AI Stickers.app"\`).
3. Set up the bot, the config and the tools it uses (ffmpeg, whisper.cpp, Claude Code): see [Install](https://github.com/nitsiyevskii/ai-stickers#install) in the README.

Universal build: Apple Silicon and Intel, macOS 14 or later.

---

## Установка

1. Скачай **AI-Stickers-$version.zip** ниже, распакуй и перетащи **AI Stickers.app** в «Программы».
2. Открой. macOS остановит первый запуск, потому что приложение не нотаризовано: **Системные настройки → Конфиденциальность и безопасность → «Всё равно открыть»** (или \`xattr -dr com.apple.quarantine "/Applications/AI Stickers.app"\`).
3. Настрой бота, конфиг и инструменты (ffmpeg, whisper.cpp, Claude Code): раздел [Установка](https://github.com/nitsiyevskii/ai-stickers/blob/main/README.ru.md#установка) в README.
EOF

gh release create "$tag" "$zip" --title "AI Stickers $version" --notes-file "$notes" --target main
