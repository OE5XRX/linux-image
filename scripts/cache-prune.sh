#!/usr/bin/env bash
# Prune the shared Yocto cache on the mounted Storage Box.
# DRY_RUN=1 (default) lists what would be removed; DRY_RUN=0 deletes.
set -euo pipefail
MIRROR="${MIRROR:-/mnt/yocto-shared}"
OE_CORE="${OE_CORE:-openembedded-core}"
DL_AGE_DAYS="${DL_AGE_DAYS:-45}"
DRY_RUN="${DRY_RUN:-1}"
mountpoint -q "$MIRROR" || { echo "error: $MIRROR not mounted" >&2; exit 1; }

echo "== leftovers: partial clones / stale locks =="
if [ "$DRY_RUN" = 1 ]; then
  find "$MIRROR/downloads/git2" -maxdepth 1 -name '*.lock' -print 2>/dev/null || true
else
  find "$MIRROR/downloads/git2" -maxdepth 1 -name '*.lock' -delete 2>/dev/null || true
fi

echo "== sstate: remove older duplicates (keep newest per object) =="
sstate_mgmt="$OE_CORE/scripts/sstate-cache-management.py"
[ -f "$sstate_mgmt" ] || sstate_mgmt="$OE_CORE/scripts/sstate-cache-management.sh"
if [ "$DRY_RUN" = 1 ]; then
  python3 "$sstate_mgmt" --cache-dir="$MIRROR/sstate" --remove-duplicated || true
else
  python3 "$sstate_mgmt" --cache-dir="$MIRROR/sstate" --remove-duplicated --yes
fi

echo "== downloads: stale files not accessed in > ${DL_AGE_DAYS} days =="
if [ "$DRY_RUN" = 1 ]; then
  find "$MIRROR/downloads" -type f -atime +"$DL_AGE_DAYS" -print | head -50
  echo "(dry-run: $(find "$MIRROR/downloads" -type f -atime +"$DL_AGE_DAYS" | wc -l) files would be removed)"
else
  find "$MIRROR/downloads" -type f -atime +"$DL_AGE_DAYS" -delete
fi
echo "cache-prune done (DRY_RUN=$DRY_RUN)"
