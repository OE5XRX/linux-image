#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env; require_session
ydev_ssh_args
run ssh -t "${YDEV_SSH[@]}" "root@$(session_ip)"
