#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# dry-run prints kas build for the default + explicit machine (no mount required)
out=$(YDEV_DRYRUN=1 bash scripts/ydev/local-build.sh 2>&1)
echo "$out" | grep -q "kas build qemux86-64.yml" || { echo "FAIL default machine: $out"; exit 1; }
out=$(YDEV_DRYRUN=1 bash scripts/ydev/local-build.sh raspberrypi4-64 2>&1)
echo "$out" | grep -q "kas build raspberrypi4-64.yml" || { echo "FAIL rpi machine: $out"; exit 1; }
# --dev flag -> dev-image target (machine still optional, defaults to qemux86-64)
out=$(YDEV_DRYRUN=1 bash scripts/ydev/local-build.sh --dev 2>&1)
echo "$out" | grep -q -- "kas build --target oe5xrx-remotestation-dev-image qemux86-64.yml" \
  || { echo "FAIL dev target: $out"; exit 1; }
echo "PASS test_local_build"
