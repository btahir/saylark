#!/usr/bin/env bash
# Builds a distributable, notarized Saylark DMG. See RELEASING.md.
#
#   scripts/release.sh                     build, sign, notarize and staple the version in packaging/Info.plist
#   scripts/release.sh --version 0.2.0     set the version first (CFBundleShortVersionString, and CFBundleVersion + 1)
#   scripts/release.sh --no-notarize       stop after the signed DMG (local check; not for distribution)
#   scripts/release.sh --publish           also create a DRAFT GitHub release v<version> with the assets
#   scripts/release.sh --publish --no-draft --latest
#                                          publish the release for real and mark it latest
#
# Options:
#   --version X.Y.Z   new marketing version, written to packaging/Info.plist
#   --build N         CFBundleVersion to use (default: unchanged, or + 1 when --version changes the version)
#   --no-notarize     skip notarization and stapling
#   --publish         create a GitHub release with gh (draft unless --no-draft)
#   --no-draft        with --publish: publish immediately instead of a draft
#   --latest          with --publish: mark the release as Latest (default: not marked)
#   --notes FILE      release notes for --publish (default: release-notes/v<version>.md, else a short generated note)
#
# Environment:
#   SL_NOTARY_PROFILE  notarytool keychain profile (default: saylark)
#   SL_SIGN_IDENTITY   codesigning identity (default: the keychain's "Developer ID Application")
#
# Outputs, in build/:
#   Saylark.app                  the signed (and stapled) app
#   Saylark-<version>.dmg        the release DMG
#   Saylark.dmg                  the same file under a stable name (for releases/latest/download/Saylark.dmg)
#   Saylark-<version>.sha256     SHA-256 checksums of both DMGs
#
# Needs only Xcode Command Line Tools (codesign, hdiutil, notarytool, stapler) and, for --publish, gh.
# It never launches the app and never handles passwords: notarization uses a keychain profile you
# store once with `xcrun notarytool store-credentials`.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=packaging/Info.plist
PROFILE="${SL_NOTARY_PROFILE:-saylark}"
TEAM_ID=Y8J6V7372T
NEW_VERSION="" NEW_BUILD="" NOTARIZE=1 PUBLISH=0 DRAFT=1 LATEST=0 NOTES=""

die() { echo "release.sh: $*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --version) NEW_VERSION="${2:-}"; shift 2 ;;
    --build) NEW_BUILD="${2:-}"; shift 2 ;;
    --no-notarize) NOTARIZE=0; shift ;;
    --publish) PUBLISH=1; shift ;;
    --no-draft) DRAFT=0; shift ;;
    --latest) LATEST=1; shift ;;
    --notes) NOTES="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

if [ "$PUBLISH" = 1 ] && [ "$NOTARIZE" = 0 ]; then die "--publish needs a notarized build; drop --no-notarize"; fi
if [ "$PUBLISH" = 0 ] && { [ "$DRAFT" = 0 ] || [ "$LATEST" = 1 ] || [ -n "$NOTES" ]; }; then
  die "--no-draft, --latest and --notes only make sense with --publish"
fi

pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }

# --- Version -----------------------------------------------------------------------------------
if [ -n "$NEW_VERSION" ]; then
  [[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "--version must look like 1.2.3, got: $NEW_VERSION"
  OLD_VERSION="$(pb 'Print :CFBundleShortVersionString')"
  if [ "$NEW_VERSION" != "$OLD_VERSION" ] && [ -z "$NEW_BUILD" ]; then
    NEW_BUILD=$(( $(pb 'Print :CFBundleVersion') + 1 ))
  fi
  pb "Set :CFBundleShortVersionString $NEW_VERSION"
fi
if [ -n "$NEW_BUILD" ]; then
  [[ "$NEW_BUILD" =~ ^[0-9]+$ ]] || die "--build must be a whole number, got: $NEW_BUILD"
  pb "Set :CFBundleVersion $NEW_BUILD"
fi
VERSION="$(pb 'Print :CFBundleShortVersionString')"
BUILD="$(pb 'Print :CFBundleVersion')"
echo "Saylark $VERSION (build $BUILD)"

# --- Preflight -----------------------------------------------------------------------------------
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
IDENTITY="${SL_SIGN_IDENTITY:-$DEVID}"
case "$IDENTITY" in
  "Developer ID Application:"*) ;;
  *) die "a release needs a Developer ID Application certificate in the keychain (found: '${IDENTITY:-none}'). See RELEASING.md." ;;
esac
export SL_SIGN_IDENTITY="$IDENTITY"

if [ "$NOTARIZE" = 1 ]; then
  # Checked before building, so a missing profile costs nothing. notarytool reads the stored
  # credentials from the keychain; this script never sees or asks for a password.
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF

release.sh: the notarization profile "$PROFILE" isn't set up (or its credentials don't work).
Nothing was submitted. Do this once, then run release.sh again:

  xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID email> --team-id $TEAM_ID

It asks for an app-specific password (create one at https://account.apple.com, Sign-In and
Security > App-Specific Passwords) and keeps it in your login keychain.
To build and check the DMG without notarizing, use --no-notarize.
EOF
    exit 2
  fi
fi

if [ "$PUBLISH" = 1 ]; then
  command -v gh >/dev/null || die "--publish needs the GitHub CLI (gh)"
  gh auth status >/dev/null 2>&1 || die "gh is not signed in (gh auth login)"
  [ -z "$(git status --porcelain)" ] || die "--publish needs a clean git tree (commit the version change first)"
  if gh release view "v$VERSION" >/dev/null 2>&1; then die "a GitHub release v$VERSION already exists"; fi
fi

# --- App -----------------------------------------------------------------------------------------
step "Building and signing build/Saylark.app"
SL_CONFIG=release scripts/bundle.sh
APP=build/Saylark.app

step "Checking the app signature"
codesign --verify --deep --strict --verbose=2 "$APP"
DETAILS="$(codesign -dvvv "$APP" 2>&1)"
grep -q 'flags=.*runtime' <<<"$DETAILS" || die "the app is not signed with the hardened runtime"
grep -q '^Timestamp=' <<<"$DETAILS" || die "the app signature has no secure timestamp"
grep -q "^TeamIdentifier=$TEAM_ID" <<<"$DETAILS" || die "the app is not signed by team $TEAM_ID"
# Every Mach-O file must be the main executable: SwiftPM resource bundles in Contents/Resources may
# hold data only. Nested code would need its own signature and fails notarization if unsigned.
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    [ "$f" = "$APP/Contents/MacOS/Saylark" ] || die "unexpected nested code in the app: $f"
  fi
done < <(find "$APP" -type f -print0)
[ "$(pb 'Print :CFBundleShortVersionString')" = "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" ] \
  || die "the app's version doesn't match $PLIST"
echo "Signature OK: Developer ID, hardened runtime, secure timestamp, no nested code."

# notarize <file>: submits and waits; prints Apple's log when it is not accepted.
notarize() {
  local file="$1" out id status
  out="$(xcrun notarytool submit "$file" --keychain-profile "$PROFILE" --wait --output-format json)" || true
  id="$(sed -n 's/.*"id" *: *"\([^"]*\)".*/\1/p' <<<"$out" | head -1)"
  status="$(sed -n 's/.*"status" *: *"\([^"]*\)".*/\1/p' <<<"$out" | head -1)"
  echo "notarytool: ${status:-no status} (submission ${id:-unknown})"
  if [ "$status" != "Accepted" ]; then
    echo "$out" >&2
    [ -n "$id" ] && xcrun notarytool log "$id" --keychain-profile "$PROFILE" >&2 || true
    die "notarization of $file was not accepted"
  fi
}

if [ "$NOTARIZE" = 1 ]; then
  # The app is notarized and stapled on its own first, so a copy dragged out of the DMG passes
  # Gatekeeper even offline. The DMG is notarized and stapled after.
  step "Notarizing the app"
  ZIP="build/Saylark-$VERSION-app.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  rm -f "$ZIP"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

# --- DMG -----------------------------------------------------------------------------------------
step "Building the DMG"
DMG="build/Saylark-$VERSION.dmg"
STABLE=build/Saylark.dmg
WORK="$(mktemp -d "${TMPDIR:-/tmp}/saylark-dmg.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ] && [ -d "$MOUNT" ]; then hdiutil detach "$MOUNT" -quiet -force || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

STAGE="$WORK/Saylark"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Saylark.app"
ln -s /Applications "$STAGE/Applications"
cp packaging/THIRD_PARTY_NOTICES.txt "$STAGE/Third-Party Notices.txt"

# A writable image first, so the volume can get Saylark's icon; then a compressed, read-only copy.
RW="$WORK/rw.dmg"
hdiutil create -quiet -volname Saylark -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
MOUNT="$WORK/mnt"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -noautoopen -readwrite -mountpoint "$MOUNT" "$RW"
cp packaging/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true   # custom volume icon (SetFile ships with the Command Line Tools)
hdiutil detach -quiet "$MOUNT"
MOUNT=""

rm -f "$DMG" "$STABLE"
hdiutil convert -quiet "$RW" -format ULFO -o "$DMG"

step "Signing the DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"

if [ "$NOTARIZE" = 1 ]; then
  step "Notarizing the DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"

  step "Gatekeeper"
  spctl -a -t open --context context:primary-signature -v "$DMG"
  spctl -a -vv "$APP"
fi

cp "$DMG" "$STABLE"

step "Checksums"
SUMS="build/Saylark-$VERSION.sha256"
( cd build && shasum -a 256 "Saylark-$VERSION.dmg" Saylark.dmg ) > "$SUMS"
cat "$SUMS"

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo
if [ "$NOTARIZE" = 1 ]; then
  echo "Done: $DMG ($SIZE), notarized and stapled. Same file: $STABLE. Checksums: $SUMS"
else
  echo "Done: $DMG ($SIZE), signed but NOT notarized (--no-notarize). Do not distribute this one."
fi

# --- GitHub release (only with --publish) --------------------------------------------------------
if [ "$PUBLISH" = 1 ]; then
  step "Creating the GitHub release v$VERSION"
  if [ -z "$NOTES" ]; then
    NOTES="release-notes/v$VERSION.md"
    if [ ! -f "$NOTES" ]; then
      NOTES="build/release-notes-v$VERSION.md"
      cat > "$NOTES" <<EOF
Saylark $VERSION for macOS 26 or later on Apple Silicon.

Download **Saylark.dmg**, open it and drag Saylark to Applications. The first launch downloads the
speech model (about 600 MB) once.

SHA-256 checksums are in \`Saylark-$VERSION.sha256\`.
EOF
    fi
  fi
  [ -f "$NOTES" ] || die "release notes not found: $NOTES"
  FLAGS=(--title "Saylark $VERSION" --notes-file "$NOTES" --target "$(git rev-parse HEAD)")
  [ "$DRAFT" = 1 ] && FLAGS+=(--draft)
  if [ "$LATEST" = 1 ]; then FLAGS+=(--latest); else FLAGS+=(--latest=false); fi
  gh release create "v$VERSION" "$DMG" "$STABLE" "$SUMS" "${FLAGS[@]}"
  if [ "$DRAFT" = 1 ]; then
    echo "Draft release created. Review it on GitHub, then publish it there (or: gh release edit v$VERSION --draft=false --latest)."
  fi
fi
