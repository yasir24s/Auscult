#!/bin/bash
# Wrap the notarised Mac app in a signed, notarised, stapled .pkg installer and
# attach it to the GitHub Release.
#
# Run after notarize-mac.sh. The app inside is already Developer ID signed and
# notarised; the installer around it needs its own signature and ticket, and
# neither can come from Xcode's cloud signing, which only covers apps. So this
# needs two things set up once, by the account holder:
#
#   1. A "Developer ID Installer" certificate in the login keychain
#      (Xcode › Settings › Accounts › Manage Certificates › + ).
#   2. Notary credentials stored in the keychain under a profile name, from an
#      App Store Connect API key (Users and Access › Integrations › Team Keys):
#        xcrun notarytool store-credentials auscult-notary \
#            --key AuthKey_<KEYID>.p8 --key-id <KEYID> --issuer <ISSUER-ID>
#      Run by the account holder; this script only ever refers to the profile
#      name, never the key. (An app-specific password also works where Apple
#      still offers them.)
#
# The script checks both up front and says exactly what is missing, rather than
# failing halfway through a notarisation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REL="${REL:-$ROOT/build/mac-release}"
APP="$REL/notarized/Auscult.app"
PROFILE="${NOTARY_PROFILE:-auscult-notary}"
TEAM="7J53W37H95"

[ -d "$APP" ] || { echo "No notarised app at $APP — run Scripts/notarize-mac.sh first." >&2; exit 1; }
xcrun stapler validate "$APP" >/dev/null \
    || { echo "$APP is not stapled — refusing to package an app Gatekeeper would question." >&2; exit 1; }

# Installer certificates are not code-signing identities, so search all of them.
IDENTITY="$(security find-identity -v 2>/dev/null \
    | sed -n "s/.*\"\(Developer ID Installer: .*($TEAM)\)\"/\1/p" | head -1)"
MISSING=()
[ -n "$IDENTITY" ] || MISSING+=("a Developer ID Installer certificate (Xcode › Settings › Accounts › Manage Certificates › +)")
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || MISSING+=("notary credentials under the keychain profile '$PROFILE' (xcrun notarytool store-credentials $PROFILE --apple-id <id> --team-id $TEAM)")
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Cannot build a signed, notarised installer yet. Missing:" >&2
    for m in "${MISSING[@]}"; do echo "  - $m" >&2; done
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILDNO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
WORK="$REL/pkg"; rm -rf "$WORK"; mkdir -p "$WORK/root/Applications"

# ditto, not cp: keeps the signature, the stapled ticket and extended attributes.
ditto "$APP" "$WORK/root/Applications/Auscult.app"

# Component package. Not relocatable: macOS will otherwise "update" whatever
# copy of Auscult it finds anywhere on disk — a stale build in ~/Downloads —
# instead of installing to /Applications, which is a confusing failure mode.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
# macOS 27's pkgbuild leaves BundleIsRelocatable out of the analysed plist
# entirely (older versions always wrote it), so "Set" alone fails. Set it if
# present, add it if not, then read it back: a relocatable installer is the bug
# this is here to prevent, so it must not pass silently.
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$WORK/components.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/components.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :0:BundleIsRelocatable' "$WORK/components.plist")" = "false" ] \
    || { echo "Could not mark the component non-relocatable." >&2; exit 1; }
pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" \
    --identifier com.yasir.auscult.pkg --version "$VERSION" \
    --install-location / "$WORK/Auscult-component.pkg"

# Product archive: this is what gets signed, notarised and shipped.
PKG="$REL/Auscult-$VERSION.pkg"
productbuild --package "$WORK/Auscult-component.pkg" --sign "$IDENTITY" --timestamp "$PKG"

echo "Notarising the installer…"
xcrun notarytool submit "$PKG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$PKG"

# What a downloader's Mac checks before it will run an installer.
# Captured first: `cmd | grep -q` under pipefail can fail on a good result when
# grep exits early and cmd dies of SIGPIPE — it rejected a correctly signed app
# in notarize-mac.sh once already.
SIG="$(pkgutil --check-signature "$PKG")"
grep -q "Developer ID Installer" <<<"$SIG" \
    || { echo "Installer is not signed with Developer ID Installer." >&2; exit 1; }
xcrun stapler validate "$PKG"
spctl -a -vv -t install "$PKG"

echo
echo "Notarised installer: $PKG  (Auscult $VERSION, build $BUILDNO)"

if [ "${RELEASE:-0}" = "1" ]; then
    command -v gh >/dev/null || { echo "RELEASE=1 needs the GitHub CLI (gh)." >&2; exit 1; }
    TAG="mac-v$VERSION"
    gh release view "$TAG" >/dev/null 2>&1 \
        || { echo "No release $TAG — publish the app first (RELEASE=1 Scripts/notarize-mac.sh)." >&2; exit 1; }
    # Fixed name, like Auscult-mac.zip, so releases/latest/download/ never moves.
    cp "$PKG" "$REL/Auscult-mac.pkg"
    gh release upload "$TAG" "$REL/Auscult-mac.pkg" --clobber
    echo "Attached to $(gh release view "$TAG" --json url -q .url)"
fi
