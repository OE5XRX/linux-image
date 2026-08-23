#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env
require_session
id=$(session_id)
run hcloud server delete "$id"
# dry-run must be side-effect free: only drop local session state on a real delete
if [ "${YDEV_DRYRUN:-0}" != "1" ]; then
  rm -f "$YDEV_SESSION" "$YDEV_KNOWN_HOSTS"
  echo "deleted ydev session box $id"
fi
