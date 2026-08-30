#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env; require_session
# Flexible args in any order: an optional machine + an optional --dev flag.
# --dev is accepted for symmetry with `build`; the rsync pulls whatever wics the
# box built (the dev wic included), so `just local qemu --dev` can boot it.
machine="qemux86-64"
for a in "$@"; do
  case "$a" in
    --dev|dev)                  ;;
    qemux86-64|raspberrypi4-64) machine="$a" ;;
    *) die_hint "unknown arg '$a'" "usage: just remote download [qemux86-64|raspberrypi4-64] [--dev]" ;;
  esac
done
ip=$(session_ip)
mkdir -p "${YDEV_ROOT}/dist/${machine}"
run rsync -az -e "$(ydev_rsh)" \
  --include='*/' --include='*.wic' --include='*.wic.*' --include='*.ext4' \
  --include='bzImage*' --include='*.dtb' --include='*.qemuboot.conf' --exclude='*' \
  "root@${ip}:/home/yocto/src/build/tmp/deploy/images/${machine}/" "${YDEV_ROOT}/dist/${machine}/"
echo "downloaded → dist/${machine}/"
