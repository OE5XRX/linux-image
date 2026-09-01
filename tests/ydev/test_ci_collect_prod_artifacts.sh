#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; export YDEV_ROOT="$tmp"
d="$tmp/dist/qemux86-64"; mkdir -p "$d"
# prod + dev images side by side, plus a signature file that must be dropped
: > "$d/oe5xrx-remotestation-image-qemux86-64.wic.bz2"
: > "$d/bzImage-qemux86-64.bin"
: > "$d/oe5xrx-remotestation-image-qemux86-64.qemuboot.conf"
: > "$d/oe5xrx-remotestation-dev-image-qemux86-64.wic.bz2"
: > "$d/oe5xrx-remotestation-image-qemux86-64.wic.bz2.p7"
bash scripts/ydev/ci-collect-prod-artifacts.sh qemux86-64
a="$tmp/artifacts"
[ -f "$a/oe5xrx-remotestation-image-qemux86-64.wic.bz2" ] || { echo "FAIL prod wic missing"; exit 1; }
[ -f "$a/bzImage-qemux86-64.bin" ] || { echo "FAIL kernel missing"; exit 1; }
[ -f "$a/oe5xrx-remotestation-image-qemux86-64.qemuboot.conf" ] || { echo "FAIL qemuboot missing"; exit 1; }
[ -e "$a/oe5xrx-remotestation-dev-image-qemux86-64.wic.bz2" ] && { echo "FAIL dev image leaked into artifact"; exit 1; }
[ -e "$a/oe5xrx-remotestation-image-qemux86-64.wic.bz2.p7" ] && { echo "FAIL .p7 leaked into artifact"; exit 1; }
echo "PASS test_ci_collect_prod_artifacts"
