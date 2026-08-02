#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env
# STRICT: only servers carrying our ownership label. CI servers (no such label) are untouched.
# clean removes ORPHANED ydev boxes only — the current live session box (if any) is spared
# (use `just remote down` to delete that one). This keeps clean/down semantics distinct.
keep=$(session_id)   # current session box id, empty if no local session
ids=$(run hcloud server list -l "managed-by==ydev" -o noheader -o columns=id 2>/dev/null || true)
if [ "${YDEV_DRYRUN:-0}" = 1 ]; then echo "DRYRUN: hcloud server list -l managed-by==ydev  → delete each except session ${keep:-none}"; exit 0; fi
[ -n "$ids" ] || { echo "no orphaned ydev boxes"; exit 0; }
session_alive=0
for id in $ids; do
  if [ -n "$keep" ] && [ "$id" = "$keep" ]; then echo "keeping active session box $id"; session_alive=1; continue; fi
  echo "deleting orphaned ydev box $id"; hcloud server delete "$id" || true
done
# drop stale local session state only when the session box is actually gone (not when spared)
[ "$session_alive" = 1 ] || rm -f "$YDEV_SESSION"
