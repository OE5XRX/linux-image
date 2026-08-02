#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env; require_session
ip=$(session_ip)
# run-qemu.sh boots the local build's qemux86-64 wic; -t for the serial console over SSH.
run ssh -t -o StrictHostKeyChecking=accept-new "root@${ip}" \
  "sudo -u yocto -H bash -lc 'cd ~/src && scripts/run-qemu.sh'"
