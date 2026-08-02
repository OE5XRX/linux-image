#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env; require_session
machine="${1:-qemux86-64}"; ip=$(session_ip)
mkdir -p "${YDEV_ROOT}/dist/${machine}"
run rsync -az -e "ssh -o StrictHostKeyChecking=accept-new" \
  --include='*/' --include='*.wic' --include='*.wic.*' --include='*.ext4' \
  --include='bzImage*' --include='*.dtb' --include='*.qemuboot.conf' --exclude='*' \
  "root@${ip}:/home/yocto/src/build/tmp/deploy/images/${machine}/" "${YDEV_ROOT}/dist/${machine}/"
echo "downloaded → dist/${machine}/"
