#!/bin/bash
# Builds "AI Stickers.app" into a fresh temp dir and prints its path.
# Usage: scripts/build-app.sh [version]   (default 1.0.0)
# UNIVERSAL=1 builds for Apple Silicon and Intel; that needs full Xcode, so only release.sh sets it.
set -euo pipefail
cd "$(dirname "$0")/.."
version="${1:-1.0.0}"

if [ "${UNIVERSAL:-}" = 1 ]; then
    swift build -c release --arch arm64 --arch x86_64 >&2
    binary=.build/apple/Products/Release/AiStickers
else
    swift build -c release >&2
    binary=.build/release/AiStickers
fi

app="$(mktemp -d)/AI Stickers.app"  # fresh every time: no stale files in the signed bundle
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/AiStickers"

iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.ilnic.ai-stickers</string>
    <key>CFBundleName</key><string>AI Stickers</string>
    <key>CFBundleDisplayName</key><string>AI Stickers</string>
    <key>CFBundleExecutable</key><string>AiStickers</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$(git rev-list --count HEAD 2>/dev/null || echo 1)</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
# Ad-hoc signature: runs on any Mac, but a downloaded copy needs "Open Anyway" once (not notarized).
codesign --force --sign - "$app" >&2

echo "$app"
