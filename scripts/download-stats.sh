#!/usr/bin/env bash
# Download counts for every GitHub release asset (GitHub counts each completed download).
# Usage: scripts/download-stats.sh            per-release table + total DMG downloads
set -euo pipefail
REPO="${SL_REPO:-btahir/saylark}"
gh api "repos/$REPO/releases" --paginate --jq '.[] | .tag_name as $t | .assets[] | [$t, .name, .download_count] | @tsv' |
  awk -F'\t' 'BEGIN{printf "%-10s %-24s %8s\n","release","asset","downloads"}
              {printf "%-10s %-24s %8d\n",$1,$2,$3; if ($2 ~ /\.dmg$/) dmg+=$3}
              END{printf "\nTotal DMG downloads: %d\n", dmg}'
