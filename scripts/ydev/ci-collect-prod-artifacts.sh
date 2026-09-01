#!/usr/bin/env bash
# CI-only: collect PROD images from dist/<machine>/ into artifacts/, excluding
# the dev-image rootfs/wic (the artifact feeds boot-ota-test, which must boot
# the prod image). Mirrors the old build.yml "Collect artifacts" find set.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"; load_env
machine="${1:-qemux86-64}"
case "$machine" in qemux86-64|raspberrypi4-64) ;; *) die_hint "unknown machine '$machine'" "qemux86-64 | raspberrypi4-64";; esac
src="${YDEV_ROOT}/dist/${machine}"
[ -d "$src" ] || die_hint "no dist dir $src" "run remote-download.sh first"
out="${YDEV_ROOT}/artifacts"; mkdir -p "$out"
# -L: follow symlinks so we copy real files, not dangling links.
find -L "$src" \
  \( -name "*.ext4" -o -name "*.wic" -o -name "*.wic.gz" \
     -o -name "*.wic.bz2" -o -name "*.wic.xz" \
     -o -name "bzImage-*" -o -name "Image-*" -o -name "zImage-*" \
     -o -name "*.qemuboot.conf" -o -name "*.dtb" \) \
  -not -name "*.p7" \
  -not -name "oe5xrx-remotestation-dev-image-*" \
  | while read -r f; do cp -L "$f" "$out/"; done
echo "collected prod artifacts → $out/"
ls -lh "$out/" || true
