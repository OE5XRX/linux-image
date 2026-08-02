#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env
require_session
id=$(session_id)
run hcloud server delete "$id"
rm -f "$YDEV_SESSION"
echo "deleted ydev session box $id"
