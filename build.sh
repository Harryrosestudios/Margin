#!/bin/bash
# Builds Margin.app into ./build. Pass --install to also copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Margin.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Margin"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Margin"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon: draw once at 1024px, then scale into an .icns.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift Resources/make-icon.swift build/icon-1024.png
for size in 16 32 128 256 512; do
    sips -z $size $size build/icon-1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) build/icon-1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" build/icon-1024.png

codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    rm -rf "/Applications/Margin.app"
    cp -R "$APP" "/Applications/Margin.app"
    echo "Installed to /Applications/Margin.app"
fi
