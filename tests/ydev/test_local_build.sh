#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# not mounted -> fails with a hint to `just local mount`
if err=$(YDEV_FORCE_MOUNTED=0 YDEV_DRYRUN=1 bash scripts/ydev/local-build.sh 2>&1); then echo "FAIL should exit nonzero"; exit 1; fi
echo "$err" | grep -q "just local mount" || { echo "FAIL mount hint: $err"; exit 1; }
# mounted -> dry-run prints kas build for the default + explicit machine
out=$(YDEV_FORCE_MOUNTED=1 YDEV_DRYRUN=1 bash scripts/ydev/local-build.sh 2>&1)
echo "$out" | grep -q "kas build qemux86-64.yml" || { echo "FAIL default machine: $out"; exit 1; }
out=$(YDEV_FORCE_MOUNTED=1 YDEV_DRYRUN=1 bash scripts/ydev/local-build.sh raspberrypi4-64 2>&1)
echo "$out" | grep -q "kas build raspberrypi4-64.yml" || { echo "FAIL rpi machine: $out"; exit 1; }
echo "PASS test_local_build"
