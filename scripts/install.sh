#!/bin/bash
# Builds "AI Stickers.app", installs it into /Applications and starts it.
# On first start it registers itself to launch at login (the menu bar item turns that off).
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

app="build/AI Stickers.app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/AiStickers "$app/Contents/MacOS/AiStickers"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.ilnic.ai-stickers</string>
    <key>CFBundleName</key><string>AI Stickers</string>
    <key>CFBundleDisplayName</key><string>AI Stickers</string>
    <key>CFBundleExecutable</key><string>AiStickers</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc signature: enough for a login item on this Mac.
codesign --force --sign - "$app"

pkill -x AiStickers || true
dest="/Applications/AI Stickers.app"
ditto "$app" "$dest"
open "$dest"
echo "Installed: $dest"
