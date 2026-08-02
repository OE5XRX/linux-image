#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; export YDEV_ROOT="$tmp"
if err=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-qemu.sh 2>&1); then echo "FAIL should exit"; exit 1; fi
echo "$err" | grep -q "just remote up" || { echo "FAIL hint: $err"; exit 1; }
printf '1 1.2.3.4 t\n' > "$tmp/.ydev-session"
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-qemu.sh 2>&1)
echo "$out" | grep -q "run-qemu.sh" || { echo "FAIL run-qemu: $out"; exit 1; }
echo "PASS test_remote_qemu"
