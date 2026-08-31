#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"; load_env
# Flexible args in any order: an optional machine + an optional --dev flag.
machine="qemux86-64"; dev=0
for a in "$@"; do
  case "$a" in
    --dev|dev)                  dev=1 ;;
    qemux86-64|raspberrypi4-64) machine="$a" ;;
    *) die_hint "unknown arg '$a'" "usage: just local build [qemux86-64|raspberrypi4-64] [--dev]" ;;
  esac
done
command -v kas >/dev/null 2>&1 || [ "${YDEV_DRYRUN:-0}" = "1" ] || die_hint "kas not installed" "pip install kas"
# The dev image only adds a few packages on top of prod; shared recipes come
# from sstate, so `--dev` is a cheap delta build, not a second full build.
if [ "$dev" = "1" ]; then
  run kas build --target oe5xrx-remotestation-dev-image "${machine}.yml"
else
  run kas build "${machine}.yml"
fi
