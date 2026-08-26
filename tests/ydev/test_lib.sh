#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/ydev/lib.sh

# run(): dry-run prints, does not execute
# shellcheck disable=SC2116
out=$(YDEV_DRYRUN=1 run echo hello)
[ "$out" = "DRYRUN: echo hello" ] || { echo "FAIL run-dryrun: '$out'"; exit 1; }
# shellcheck disable=SC2116
out=$(YDEV_DRYRUN=0 run echo hello)
[ "$out" = "hello" ] || { echo "FAIL run-real: '$out'"; exit 1; }

# die_hint(): exits 1 and prints msg + fix to stderr
if err=$( (die_hint "boom" "do X") 2>&1 ); then echo "FAIL die_hint exit"; exit 1; fi
echo "$err" | grep -q "boom" || { echo "FAIL die_hint msg"; exit 1; }
echo "$err" | grep -q "do X" || { echo "FAIL die_hint fix"; exit 1; }

echo "PASS test_lib"
