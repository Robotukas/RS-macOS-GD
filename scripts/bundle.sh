#!/bin/zsh
# Build GDHub and assemble a runnable .app bundle at .build/GDHub.app, then launch it.
set -e -o pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
CONFIG="${1:-debug}"
swift build -c "$CONFIG" 2>&1 | grep -vE 'ld: warning: search path' | tail -3
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP=".build/GDHub.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/GDHub" "$APP/Contents/MacOS/GDHub"
cp -R "$BIN/GDHub_GDHub.bundle" "$APP/Contents/Resources/" 2>/dev/null || true
cp -R "$BIN/GDHub_GDHub.bundle" "$APP/Contents/MacOS/" 2>/dev/null || true
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>GDHub</string>
  <key>CFBundleDisplayName</key><string>GDHub</string>
  <key>CFBundleIdentifier</key><string>com.interlinked.gdhub</string>
  <key>CFBundleExecutable</key><string>GDHub</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "bundled $APP"
[[ "$2" == "--no-open" ]] && exit 0
pkill -f "GDHub.app/Contents/MacOS/GDHub" 2>/dev/null && sleep 0.5
open "$APP"
