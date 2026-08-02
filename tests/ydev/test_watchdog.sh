#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
sh -n scripts/ydev/box/ydev-watchdog.sh || { echo "FAIL syntax"; exit 1; }
# active (fake bitbake present) -> resets idle, does NOT delete
out=$(YDEV_DRYRUN=1 YDEV_TEST_BUSY=1 YDEV_STATE="$(mktemp -d)/s" bash scripts/ydev/box/ydev-watchdog.sh 2>&1)
echo "$out" | grep -qi "busy\|active" || { echo "FAIL busy path: $out"; exit 1; }
echo "$out" | grep -qi "server delete" && { echo "FAIL deleted while busy"; exit 1; }
# idle past threshold -> dry-run self-delete
st="$(mktemp -d)/s"; echo 0 > "$st"   # idle-since epoch 0 = long ago
out=$(YDEV_DRYRUN=1 YDEV_TEST_BUSY=0 YDEV_IDLE_MINUTES=1 YDEV_STATE="$st" YDEV_SELF_ID=999 bash scripts/ydev/box/ydev-watchdog.sh 2>&1)
echo "$out" | grep -q "server delete" && echo "$out" | grep -q "999" || { echo "FAIL idle delete: $out"; exit 1; }
echo "PASS test_watchdog"
