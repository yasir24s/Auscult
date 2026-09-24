#!/bin/bash
# Build, sign with Developer ID, notarise, staple and zip the macOS app.
#
# The Mac app cannot ship through TestFlight (App Sandbox denies the usbmuxd
# socket — see README, "Distribution"), so it ships as a notarised download.
#
# Everything runs through Xcode's archive/export pipeline, because that is what
# can use a cloud-managed Developer ID certificate and submit to the notary
# service on the account already signed into Xcode. There is no local
# Developer ID certificate, app-specific password or API key involved — the same
# property that lets archive-agent.sh upload to App Store Connect.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/mac-release}"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD="$(xcodebuild -version | sed -n 's/^Build version //p')"
if [[ "$BUILD" =~ ^[0-9]+[A-Z]5[0-9]{3} ]]; then
    echo "Refusing: $BUILD is a beta seed. Notarising a beta-built app ships beta SDK code." >&2
    exit 1
fi
echo "Xcode build $BUILD (release)"

cd "$ROOT/Mac"
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate

rm -rf "$OUT"; mkdir -p "$OUT"
ARCHIVE="$OUT/Auscult.xcarchive"

xcodebuild -project Auscult.xcodeproj -scheme Auscult -configuration Release \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates archive

# A command-line tool target without SKIP_INSTALL turns this into a "generic"
# archive that cannot be exported as an app. Catch that here, not at export.
/usr/libexec/PlistBuddy -c "Print :ApplicationProperties:ApplicationPath" \
    "$ARCHIVE/Info.plist" >/dev/null 2>&1 \
    || { echo "Archive is not an app archive — check SKIP_INSTALL on the CLI target." >&2; exit 1; }

cat > "$OUT/notarizeOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>7J53W37H95</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>upload</string>
</dict></plist>
PLIST

# Signs with Developer ID and submits to the notary service in one step.
# Nothing is written locally: the signed app goes straight to Apple.
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/notarizeOptions.plist" \
    -exportPath "$OUT/submitted" -allowProvisioningUpdates

# Fetch it back once Apple has notarised it; this also staples the ticket.
echo "Waiting for notarisation…"
for attempt in $(seq 1 45); do
    if RESULT="$(xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" \
                   -exportPath "$OUT/notarized" 2>&1)"; then
        break
    fi
    if echo "$RESULT" | grep -qiE "invalid|rejected"; then
        echo "$RESULT" >&2; echo "Notarisation was rejected." >&2; exit 1
    fi
    [ "$attempt" -eq 45 ] && { echo "Timed out waiting for notarisation." >&2; exit 1; }
    sleep 20
done

APP="$OUT/notarized/Auscult.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"

# Verify what a downloader's Mac will check, including the embedded CLI —
# every executable in the bundle must carry the Developer ID signature.
# Capture first, then grep. Piping codesign into `grep -q` under pipefail
# fails on a GOOD app: grep exits at the first match, codesign dies of SIGPIPE
# writing the rest, and pipefail reports that — which is exactly how the first
# end-to-end run of this script rejected a correctly signed, stapled app.
for bin in "$APP" "$APP/Contents/Helpers/auscult"; do
    SIG="$(codesign -dvv "$bin" 2>&1)"
    grep -q "^Authority=Developer ID Application" <<<"$SIG" \
        || { echo "$bin is not Developer ID signed." >&2; exit 1; }
    grep -q "flags=0x10000(runtime)" <<<"$SIG" \
        || { echo "$bin lacks the hardened runtime." >&2; exit 1; }
    grep -q "^Timestamp=" <<<"$SIG" \
        || { echo "$bin has no secure timestamp." >&2; exit 1; }
done
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl -a -t exec "$APP"

ZIP="$OUT/Auscult-$VERSION.zip"
# ditto, not zip: it preserves the extended attributes and signature layout.
ditto -c -k --keepParent "$APP" "$ZIP"

echo
echo "Notarised and stapled: $ZIP"
spctl -a -vv -t exec "$APP" 2>&1 | sed -n 's/^/  /p'
