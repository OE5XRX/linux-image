#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"; load_env
machine="${1:-qemux86-64}"
variant="${2:-}"
case "$machine" in qemux86-64|raspberrypi4-64) ;; *) die_hint "unknown machine '$machine'" "use qemux86-64 or raspberrypi4-64";; esac
command -v kas >/dev/null 2>&1 || [ "${YDEV_DRYRUN:-0}" = "1" ] || die_hint "kas not installed" "pip install kas"
# The dev image only adds a few packages on top of prod; shared recipes come
# from sstate, so `dev` is a cheap delta build, not a second full build.
case "$variant" in
  "")  run kas build "${machine}.yml" ;;
  dev) run kas build --target oe5xrx-remotestation-dev-image "${machine}.yml" ;;
  *)   die_hint "unknown variant '$variant'" "use 'dev' or leave empty for the prod image" ;;
esac
