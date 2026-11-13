#!/bin/zsh
# Builds Blink.app (icon + sounds included), installs it to ~/Applications and launches it.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Blink.app
RES="$APP/Contents/Resources"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$RES" build/tmp

echo "→ compiling"
swiftc -O -parse-as-library -swift-version 5 Blink.swift -o "$APP/Contents/MacOS/Blink"

echo "→ painting icon"
swiftc -O tools/icon.swift -o build/tmp/icon
build/tmp/icon build/tmp/icon.png
ICONSET=build/tmp/AppIcon.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s build/tmp/icon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/tmp/icon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns"

echo "→ synthesizing sounds"
python3 tools/sounds.py "$RES"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Blink</string>
  <key>CFBundleDisplayName</key><string>Blink</string>
  <key>CFBundleIdentifier</key><string>local.blink.reminders</string>
  <key>CFBundleExecutable</key><string>Blink</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

rm -rf build/tmp
codesign --force --deep -s - "$APP" >/dev/null

pkill -x Blink 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Blink.app
cp -R "$APP" ~/Applications/
touch ~/Applications/Blink.app   # nudge Finder to refresh the icon
open ~/Applications/Blink.app
echo "✓ Blink is running — click the bell, or press ⌥⌘B anywhere."
