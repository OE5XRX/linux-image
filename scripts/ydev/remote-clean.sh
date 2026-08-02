#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env
# STRICT: only servers carrying our ownership label. CI servers (no such label) are untouched.
ids=$(run hcloud server list -l "managed-by==ydev" -o noheader -o columns=id 2>/dev/null || true)
if [ "${YDEV_DRYRUN:-0}" = 1 ]; then echo "DRYRUN: hcloud server list -l managed-by==ydev  → delete each"; exit 0; fi
[ -n "$ids" ] || { echo "no orphaned ydev boxes"; exit 0; }
for id in $ids; do echo "deleting orphaned ydev box $id"; hcloud server delete "$id" || true; done
rm -f "$YDEV_SESSION"
