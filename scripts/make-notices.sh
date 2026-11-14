#!/usr/bin/env bash
# Writes packaging/THIRD_PARTY_NOTICES.txt from the license files of the resolved dependencies.
# Run it after changing a dependency version (it needs a build folder with the checkouts):
#   scripts/make-notices.sh [checkouts dir]     default: .build-ui/checkouts, else .build/checkouts
# bundle.sh copies the result into the app (Contents/Resources) and release.sh into the DMG.
set -euo pipefail
cd "$(dirname "$0")/.."
CO="${1:-}"
if [ -z "$CO" ]; then
  for d in .build-ui/checkouts .build/checkouts; do [ -d "$d/FluidAudio" ] && CO="$d" && break; done
fi
[ -n "$CO" ] && [ -d "$CO/FluidAudio" ] && [ -d "$CO/GRDB.swift" ] || { echo "make-notices.sh: no checkouts found; run swift build first" >&2; exit 1; }

version() { sed -n "/\"identity\" : \"$1\"/,/version/s/.*\"version\" : \"\([^\"]*\)\".*/\1/p" Package.resolved | head -1; }
rule() { printf '\n%s\n%s\n\n' "================================================================================" "$1"; }

OUT=packaging/THIRD_PARTY_NOTICES.txt
{
  cat <<'EOF'
Saylark third-party notices

Saylark is MIT-licensed (see LICENSE). It includes or downloads the following works.

Software built into the app
  - GRDB.swift                     MIT                 https://github.com/groue/GRDB.swift
  - FluidAudio                     Apache-2.0          https://github.com/FluidInference/FluidAudio
  - fastcluster (via FluidAudio)   BSD-2-Clause        https://danifold.net/fastcluster.html
  - text-processing-rs / NeMo text processing (static library via FluidAudio)
                                   Apache-2.0          https://github.com/FluidInference/text-processing-rs
                                                       https://github.com/NVIDIA/NeMo-text-processing

Models downloaded on first launch (from huggingface.co, not included in the app)
  - Parakeet Ultra speech model    CC-BY-4.0           https://huggingface.co/FluidInference/parakeet-ultra-coreml
      Based on NVIDIA Parakeet TDT 0.6B (CC-BY-4.0), post-trained as Parakeet Ultra by Moondream,
      converted to Core ML by FluidInference. Saylark uses it unmodified.
  - Silero VAD voice activity model MIT                https://huggingface.co/FluidInference/silero-vad-coreml
      Silero VAD by Silero Team (https://github.com/snakers4/silero-vad), converted to Core ML by FluidInference.
  - Parakeet CTC 110M (spelling model, downloaded only when your dictionary has terms)
                                   CC-BY-4.0           https://huggingface.co/FluidInference/parakeet-ctc-110m-coreml
      Based on NVIDIA Parakeet CTC 110M (CC-BY-4.0), converted to Core ML by FluidInference.

CC-BY-4.0 license text: https://creativecommons.org/licenses/by/4.0/legalcode
EOF
  rule "GRDB.swift $(version grdb.swift)"
  cat "$CO/GRDB.swift/LICENSE"
  rule "FluidAudio $(version fluidaudio) (Apache License 2.0)"
  cat "$CO/FluidAudio/LICENSE"
  rule "fastcluster (included in FluidAudio)"
  cat "$CO/FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md"
  rule "NemoTextProcessing / text-processing-rs (included in FluidAudio)"
  cat "$CO/FluidAudio/ThirdPartyLicenses/NemoTextProcessing-LICENSE.md"
} > "$OUT"
echo "Wrote $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"
