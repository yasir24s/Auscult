#!/bin/bash
# Wrap the SwiftPM executable into a real .app bundle.
#
# SwiftUI needs a bundle to behave properly — without one you get no menu bar,
# no window restoration, and no Info.plist for the usage strings. Building the
# GUI this way keeps the whole project buildable from the command line with no
# .xcodeproj to maintain.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product AuscultApp
swift build -c "$CONFIG" --product auscult

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/Auscult.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/AuscultApp" "$APP/Contents/MacOS/Auscult"

# Ship the CLI inside the bundle so both stay in lockstep, but *not* in
# MacOS/ — the default macOS filesystem is case-insensitive, so "auscult"
# and "Auscult" are the same path there and the CLI would clobber the app.
mkdir -p "$APP/Contents/Helpers"
cp "$BIN_DIR/auscult" "$APP/Contents/Helpers/auscult"

# Bundled SwiftPM resources (the knowledge tables) live beside the binary.
for b in "$BIN_DIR"/*.bundle; do
    [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>Auscult</string>
    <key>CFBundleDisplayName</key>       <string>Auscult</string>
    <key>CFBundleIdentifier</key>        <string>com.yasir.auscult</string>
    <key>CFBundleExecutable</key>        <string>Auscult</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key>           <string>1</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <key>NSHighResolutionCapable</key>   <true/>
    <key>LSApplicationCategoryType</key> <string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key>  <string>Auscult — iOS device diagnostics</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so macOS will run it locally without a Gatekeeper prompt loop.
codesign --force --deep --sign - "$APP" 2>/dev/null \
    && echo "Signed ad-hoc." \
    || echo "Warning: ad-hoc signing failed; the app may still run."

echo "Built $APP"
