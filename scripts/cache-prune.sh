#!/usr/bin/env bash
# Prune the shared Yocto cache on the mounted Storage Box.
# DRY_RUN=1 (default) lists what would be removed; DRY_RUN=0 deletes.
set -euo pipefail
MIRROR="${MIRROR:-/mnt/yocto-shared}"
OE_CORE="${OE_CORE:-openembedded-core}"
DL_AGE_DAYS="${DL_AGE_DAYS:-45}"
# Leftover fetch artifacts (aborted .tmp tarballs + stale .lock) are guarded by
# idle-minutes, not days: a live fetch keeps touching its .tmp, so an artifact
# untouched for hours is dead. 360 min (6 h) is far longer than any shallow
# fetch yet short enough to reclaim GB-sized aborted mirror tarballs.
LEFTOVER_AGE_MIN="${LEFTOVER_AGE_MIN:-360}"
DRY_RUN="${DRY_RUN:-1}"
# Fail closed: only 0/1 accepted. A typo like DRY_RUN=false must NOT delete
# (the workflow validates its input, but local/manual runs come straight here).
case "$DRY_RUN" in 0|1) ;; *) echo "error: DRY_RUN must be 0 or 1, got '$DRY_RUN'" >&2; exit 1 ;; esac
mountpoint -q "$MIRROR" || { echo "error: $MIRROR not mounted" >&2; exit 1; }

echo "== leftovers: aborted tarballs + stale .lock files (idle > ${LEFTOVER_AGE_MIN} min) =="
# An interrupted fetch leaves a partial mirror/shallow tarball (downloads/*.tar.gz.tmp
# — can be GBs) plus a stale fetch lock (root DL_DIR and/or git2/). The old cleanup
# only caught git2/*.lock, so multi-GB root-level .tmp leftovers piled up. Guard by
# idle-minutes (-mmin) so a concurrent in-progress fetch is never removed.
prune_leftovers() {
  # $1 = extra find action ('-print' | '-delete')
  find "$MIRROR/downloads" -maxdepth 1 -type f \
    \( -name '*.tar.gz.tmp' -o -name '*.lock' \) -mmin +"$LEFTOVER_AGE_MIN" "$1" 2>/dev/null || true
  find "$MIRROR/downloads/git2" -maxdepth 1 -type f \
    -name '*.lock' -mmin +"$LEFTOVER_AGE_MIN" "$1" 2>/dev/null || true
}
if [ "$DRY_RUN" = 1 ]; then
  prune_leftovers -print
else
  prune_leftovers -delete
fi

echo "== sstate: remove older duplicates (keep newest per object) =="
# OE ships the tool as .py (current) or .sh (legacy); invoke each with its own
# interpreter — running a .sh via python3 (or vice versa) would fail.
if [ -f "$OE_CORE/scripts/sstate-cache-management.py" ]; then
  sstate_mgmt=(python3 "$OE_CORE/scripts/sstate-cache-management.py")
else
  sstate_mgmt=("$OE_CORE/scripts/sstate-cache-management.sh")
fi
if [ "$DRY_RUN" = 1 ]; then
  # --dry-run (-n): the tool's own no-op mode; clean output, exits 0. Avoids
  # the interactive input() prompt that would EOFError under CI.
  "${sstate_mgmt[@]}" --cache-dir="$MIRROR/sstate" --remove-duplicated --dry-run
else
  "${sstate_mgmt[@]}" --cache-dir="$MIRROR/sstate" --remove-duplicated --yes
fi

echo "== downloads: stale files not accessed in > ${DL_AGE_DAYS} days =="
if [ "$DRY_RUN" = 1 ]; then
  find "$MIRROR/downloads" -type f -atime +"$DL_AGE_DAYS" -print | head -50
  echo "(dry-run: $(find "$MIRROR/downloads" -type f -atime +"$DL_AGE_DAYS" | wc -l) files would be removed)"
else
  find "$MIRROR/downloads" -type f -atime +"$DL_AGE_DAYS" -delete
fi
echo "cache-prune done (DRY_RUN=$DRY_RUN)"
