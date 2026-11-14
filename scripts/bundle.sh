#!/usr/bin/env bash
# Builds build/Saylark.app: the menu bar app (LSUIElement), icon and onboarding art, signed with
# hardened runtime and the audio-input entitlement. Signing with the same Developer ID every time
# keeps the macOS permissions (Microphone, Input Monitoring) across rebuilds.
#   SL_SIGN_IDENTITY  codesigning identity (default: the keychain's "Developer ID Application")
#   ALLOW_ADHOC=1     allow ad hoc signing when there is no Developer ID. Off by default: an ad hoc build
#                     has a new identity on every rebuild, so macOS forgets the Microphone and Input
#                     Monitoring grants each time.
#   SL_CONFIG         debug|release (default release)
#   SL_SCRATCH        build folder (default .build-ui)
# Builds only. It never launches the app.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
CONFIG="${SL_CONFIG:-release}"
SCRATCH="${SL_SCRATCH:-.build-ui}"
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
IDENTITY="${SL_SIGN_IDENTITY:-${DEVID:--}}"
if [ "$IDENTITY" = "-" ] && [ "${ALLOW_ADHOC:-0}" != 1 ]; then
  {
    echo "bundle.sh: no Developer ID Application identity found, so this would be signed ad hoc."
    echo "An ad hoc build gets a new identity on every rebuild, and macOS then resets Saylark's"
    echo "Microphone and Input Monitoring permissions each time."
    echo "Fix: install the Developer ID certificate (check: security find-identity -v -p codesigning),"
    echo "or set SL_SIGN_IDENTITY, or run with ALLOW_ADHOC=1 if you really want an ad hoc build."
  } >&2
  exit 1
fi
# Notarization needs a secure timestamp; ad hoc signing skips the network round trip.
TIMESTAMP=(--timestamp=none)
case "$IDENTITY" in "Developer ID Application:"*) TIMESTAMP=(--timestamp) ;; esac

swift build -c "$CONFIG" --scratch-path "$SCRATCH" --product SaylarkApp
BIN="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH" --show-bin-path)"

APP=build/Saylark.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SaylarkApp" "$APP/Contents/MacOS/Saylark"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp packaging/Art/*.png "$APP/Contents/Resources/"
# The About panel shows Credits.html; the full third-party notices sit next to it.
cp packaging/Credits.html packaging/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/"
# SwiftPM resource bundles (dependencies), if any. They hold data only (release.sh checks there is no
# nested code), so the app's own signature seals them as resources.
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Extended attributes (Finder info, quarantine) on bundle files break the signature seal.
xattr -cr "$APP"

codesign --force --options runtime "${TIMESTAMP[@]}" --entitlements packaging/Saylark.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($CONFIG, signed with: $IDENTITY)"
