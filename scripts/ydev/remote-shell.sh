#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env; require_session
run ssh -t -o StrictHostKeyChecking=accept-new "root@$(session_ip)"
