#!/usr/bin/env bash
# Rebuilds packaging/AppIcon.icns (and, optionally, the onboarding art) from source artwork.
# The source art is not in the repo; the built files in packaging/ are what the app uses.
#   scripts/make-icon.sh <icon.png> [onboarding-welcome.png]
#     icon.png                  square source art, 1024 px or larger
#     onboarding-welcome.png    2:1 art for the onboarding welcome step (written at 880x440)
# Needs only the Command Line Tools (swiftc, iconutil, sips).
set -euo pipefail
cd "$(dirname "$0")/.."
ART="${1:-}"
WELCOME="${2:-}"
[ -n "$ART" ] && [ -f "$ART" ] || { echo "usage: scripts/make-icon.sh <icon.png> [onboarding-welcome.png]" >&2; exit 2; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/saylark-icon.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

swiftc -O packaging/tools/make-icon.swift -o "$WORK/make-icon"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for pt in 16 32 128 256 512; do
  "$WORK/make-icon" "$ART" "$ICONSET/icon_${pt}x${pt}.png" "$pt"
  "$WORK/make-icon" "$ART" "$ICONSET/icon_${pt}x${pt}@2x.png" "$((pt * 2))"
done
iconutil --convert icns "$ICONSET" --output packaging/AppIcon.icns
echo "Wrote packaging/AppIcon.icns"

if [ -n "$WELCOME" ]; then
  # Onboarding art at 2x its point size in the window.
  sips -z 440 880 "$WELCOME" --out packaging/Art/onboarding-welcome.png >/dev/null
  echo "Wrote packaging/Art/onboarding-welcome.png"
fi
