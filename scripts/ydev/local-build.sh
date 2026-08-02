#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"; load_env
machine="${1:-qemux86-64}"
case "$machine" in qemux86-64|raspberrypi4-64) ;; *) die_hint "unknown machine '$machine'" "use qemux86-64 or raspberrypi4-64";; esac
mirror_mounted || die_hint "shared mirror not mounted at $MIRROR_MNT" "just local mount"
command -v kas >/dev/null 2>&1 || [ "${YDEV_DRYRUN:-0}" = "1" ] || die_hint "kas not installed" "pip install kas"
run kas build "${machine}.yml"
