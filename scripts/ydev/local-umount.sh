#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"
if mountpoint -q "$MIRROR_MNT"; then run fusermount3 -u "$MIRROR_MNT" 2>/dev/null || run fusermount -u "$MIRROR_MNT"; echo "unmounted $MIRROR_MNT"; else echo "not mounted: $MIRROR_MNT"; fi
