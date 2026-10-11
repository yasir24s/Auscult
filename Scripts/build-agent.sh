#!/bin/bash
# Build, sign, and install the on-device agent.
#
# Uses whichever Xcode has an SDK matching the *device*, not whatever
# xcode-select points at: the host tooling and the agent have different
# requirements, and a device on an iOS seed needs the matching seed SDK.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UDID="${1:-}"

# Prefer the newest installed Xcode; it carries the newest iOS SDK.
for candidate in /Applications/Xcode-27-beta.app /Applications/Xcode-beta.app /Applications/Xcode.app; do
    if [ -d "$candidate" ]; then
        export DEVELOPER_DIR="$candidate/Contents/Developer"
        break
    fi
done
echo "Using $(xcodebuild -version | head -1)"

SDK="$(xcodebuild -showsdks 2>/dev/null | grep -oE 'iphoneos[0-9.]+' | tail -1)"
[ -n "$SDK" ] || { echo "No iOS SDK found." >&2; exit 1; }
echo "Building against $SDK"

cd "$ROOT/Agent"
command -v xcodegen >/dev/null || { echo "xcodegen is required: brew install xcodegen" >&2; exit 1; }
xcodegen generate

xcodebuild -project AuscultAgent.xcodeproj -scheme AuscultAgent \
    -configuration Release -sdk "$SDK" -destination 'generic/platform=iOS' \
    -derivedDataPath build -allowProvisioningUpdates build

APP="build/Build/Products/Release-iphoneos/Auscult Agent.app"
[ -d "$APP" ] || { echo "Build produced no app bundle." >&2; exit 1; }

if [ -z "$UDID" ]; then
    # auscult masks UDIDs in its output, so ask devicectl for the first
    # connected iPhone or iPad instead.
    UDID="$(xcrun devicectl list devices --json-output /dev/stdout --quiet 2>/dev/null | python3 -c '
import json, sys
for d in json.load(sys.stdin)["result"]["devices"]:
    hw = d.get("hardwareProperties", {})
    if hw.get("platform") == "iOS" and d.get("connectionProperties", {}).get("tunnelState") != "unavailable":
        print(hw.get("udid", "")); break
')" || true
fi
[ -n "$UDID" ] || { echo "No device found. Pass a UDID, or connect one over USB." >&2; exit 1; }

echo "Installing to $UDID"
xcrun devicectl device install app --device "$UDID" "$APP"

cat <<NOTE

Installed. On a first install, trust the developer profile on the device:
  Settings > General > VPN & Device Management > Developer App > Trust

Then open the agent and keep it in the foreground; iOS suspends backgrounded
apps and the listening socket dies with them.
NOTE
