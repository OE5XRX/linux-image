#!/usr/bin/env bash
# CI-only: collect the DEV image wic from dist/<machine>/ into artifacts-dev/.
# Counterpart to ci-collect-prod-artifacts.sh — that one EXCLUDES the dev
# image; this one includes ONLY it, so release.yml can package both channels.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"; load_env
machine="${1:-qemux86-64}"
case "$machine" in qemux86-64|raspberrypi4-64) ;; *) die_hint "unknown machine '$machine'" "qemux86-64 | raspberrypi4-64";; esac
src="${YDEV_ROOT}/dist/${machine}"
[ -d "$src" ] || die_hint "no dist dir $src" "run remote-download.sh first"
out="${YDEV_ROOT}/artifacts-dev"; mkdir -p "$out"
find -L "$src" \
  \( -name "oe5xrx-remotestation-dev-image-*.wic" \
     -o -name "oe5xrx-remotestation-dev-image-*.wic.gz" \
     -o -name "oe5xrx-remotestation-dev-image-*.wic.bz2" \
     -o -name "oe5xrx-remotestation-dev-image-*.wic.xz" \) \
  -not -name "*.p7" \
  | while read -r f; do cp -L "$f" "$out/"; done
echo "collected dev artifacts → $out/"
ls -lh "$out/" || true
