#!/usr/bin/env bash
#
# Trigger a release. The release is a one-button `workflow_dispatch` that
# computes its own next version (YYYY.MM.DD-HH[a-z]) server-side, builds both
# images, gates publication on the boot + OTA integration test, and publishes a
# signed GitHub Release. There is no local tag push anymore — this script is a
# thin wrapper around `gh workflow run`.
#
# Usage:
#   scripts/release.sh            # real release (must run on the default branch)
#   scripts/release.sh --dry-run  # build + gate only, no sign/tag/publish
#   scripts/release.sh --ref BR   # dispatch against a specific branch (for dry runs)

set -euo pipefail

DRY_RUN=0
REF=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        --ref)        REF="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

args=(release.yml)
[[ -n "$REF" ]] && args+=(--ref "$REF")
[[ "$DRY_RUN" -eq 1 ]] && args+=(-f dry_run=true)

echo "Dispatching: gh workflow run ${args[*]}"
exec gh workflow run "${args[@]}"
