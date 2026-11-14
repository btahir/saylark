#!/usr/bin/env bash
# Runs the test suite. Extra arguments go to `swift test`, e.g. scripts/test.sh --filter DictionaryFileTests
# Set SL_SCRATCH to use a separate build directory (parallel worktrees).
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
PLUGINS="$(dirname "$(dirname "$(xcrun --find swift)")")/lib/swift/host/plugins/testing"
ARGS=()
[ -d "$PLUGINS" ] && ARGS+=(-Xswiftc -plugin-path -Xswiftc "$PLUGINS")
[ -n "${SL_SCRATCH:-}" ] && ARGS+=(--scratch-path "$SL_SCRATCH")
# Tests write recordings and exports to the temp folder (about 1 GB a run). Give each run its own
# folder and remove it afterwards, so nothing piles up. Set SL_KEEP_TEST_TMP=1 to keep it.
RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/saylark-test-run.XXXXXX")"; RUN_TMP="$(cd "$RUN_TMP" && pwd)"
if [ "${SL_KEEP_TEST_TMP:-0}" != 1 ]; then trap 'rm -rf "$RUN_TMP"' EXIT; else echo "Keeping test files in $RUN_TMP"; fi
export TMPDIR="$RUN_TMP/" SL_TEST_TMP="$RUN_TMP"
swift test ${ARGS[@]+"${ARGS[@]}"} "$@"
