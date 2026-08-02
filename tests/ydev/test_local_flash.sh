#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# no device -> usage + lists devices, exits nonzero
if out=$(bash scripts/ydev/local-flash.sh 2>&1); then echo "FAIL no-device should exit nonzero"; exit 1; fi
echo "$out" | grep -qi "usage" || { echo "FAIL usage: $out"; exit 1; }
# non-block device -> refuse
if err=$(bash scripts/ydev/local-flash.sh /tmp 2>&1); then echo "FAIL /tmp should be refused"; exit 1; fi
echo "$err" | grep -qi "block device" || { echo "FAIL block-check: $err"; exit 1; }
echo "PASS test_local_flash"
