#!/bin/bash
# Archive the agent for TestFlight and export a distribution-signed .ipa.
#
# Deliberately separate from build-agent.sh: that script picks the *newest*
# Xcode so a device on an iOS seed gets a matching SDK, which is right for
# sideloading and fatal here. App Store Connect rejects any upload built with
# a beta Xcode -- and it does so server-side, after the upload finishes, so
# nothing local catches it. Release Xcode is pinned by hand for that reason.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/build/testflight}"

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
BUILD="$(xcodebuild -version | sed -n 's/^Build version //p')"
# Beta seeds carry a 4-digit block starting with 5 (27A5252f); the release is
# 27A266a. Compare the number, not the trailing letter -- both have one.
if [[ "$BUILD" =~ ^[0-9]+[A-Z]5[0-9]{3} ]]; then
    echo "Refusing to archive: $BUILD is a beta seed. App Store Connect will reject it." >&2
    exit 1
fi
echo "Xcode build $BUILD (release)"

cd "$ROOT/Agent"
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate

ARCHIVE="$OUT/AuscultAgent.xcarchive"
rm -rf "$OUT"; mkdir -p "$OUT"

xcodebuild -project AuscultAgent.xcodeproj -scheme AuscultAgent \
    -configuration Release -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" -allowProvisioningUpdates archive

cat > "$OUT/exportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>7J53W37H95</string>
  <key>signingStyle</key><string>automatic</string>
  <key>uploadSymbols</key><true/>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST

# The archive itself signs with Apple Development; the distribution identity
# and the Store profile are applied here, at export. Checking the signature on
# the archive rather than on the .ipa will mislead you.
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$OUT/exportOptions.plist" -exportPath "$OUT" \
    -allowProvisioningUpdates

IPA="$(ls "$OUT"/*.ipa)"
echo
echo "Exported $IPA"
codesign -dvvv "$ARCHIVE/Products/Applications/Auscult Agent.app" 2>&1 | grep -E "^Authority=Apple" | head -1

if [ "${UPLOAD:-0}" = "1" ]; then
    # destination=upload rides the account already signed into Xcode -- the
    # same session that mints the distribution cert and Store profile during
    # export. No App Store Connect API key and no app-specific password are
    # needed, which is not obvious: every altool invocation demands one or the
    # other, so it looks like CLI upload requires credentials. It does not.
    sed 's|<string>export</string>|<string>upload</string>|' \
        "$OUT/exportOptions.plist" > "$OUT/uploadOptions.plist"
    xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$OUT/uploadOptions.plist" \
        -exportPath "$OUT/upload" -allowProvisioningUpdates
    cat <<'NOTE'

Uploaded. "Upload succeeded" is not the final word: App Store Connect runs its
beta-SDK check during *processing*, after the transfer completes, and a build
made with a seed Xcode is rejected by email at that point. The guard at the top
of this script is what prevents that.
NOTE
else
    cat <<NOTE

Not uploaded. Re-run with UPLOAD=1 to send it:

    UPLOAD=1 $0

An App Store Connect app record for com.yasir.auscult.agent must exist first;
registering the bundle ID is not the same thing.
NOTE
fi
