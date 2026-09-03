#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env
require_session
id=$(session_id)
# Idempotent teardown: the box also self-deletes via its cloud-init idle/max-life
# watchdog, which can win the race and remove it before this explicit teardown —
# then `hcloud server delete` reports "Server not found" and aborts the job under
# `set -e`, even though the box is already gone (exactly the desired end state).
# Delete is by GLOBAL server-id, so no location/datacenter is involved. Treat an
# already-gone box as success; the cloud-init self-teardown is the real guarantee
# (same best-effort pattern as remote-clean.sh).
run hcloud server delete "$id" || echo "ydev: box $id already gone (self-teardown won the race) — treating as deleted"
# dry-run must be side-effect free: only drop local session state on a real delete
if [ "${YDEV_DRYRUN:-0}" != "1" ]; then
  rm -f "$YDEV_SESSION" "$YDEV_KNOWN_HOSTS"
  echo "deleted ydev session box $id"
fi
