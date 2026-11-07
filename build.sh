#!/bin/bash
# Builds Solace.app and Solace.zip in ./build  (needs Xcode or Command Line Tools: xcode-select --install)
set -euo pipefail
cd "$(dirname "$0")"

APP=Solace
OUT=build
BUNDLE="$OUT/$APP.app"

echo "→ Compiling (release)…"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/$APP"

echo "→ Assembling $APP.app…"
rm -rf "$BUNDLE" "$OUT/$APP.zip"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"

if [ -f Resources/AppIcon.png ]; then
  ICONSET="$OUT/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

echo "→ Signing (ad-hoc)…"
codesign --force --deep --sign - "$BUNDLE"

echo "→ Zipping…"
ditto -c -k --keepParent "$BUNDLE" "$OUT/$APP.zip"

echo "✓ Done: $BUNDLE  and  $OUT/$APP.zip"
