#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export YDEV_ROOT="$tmp" YDEV_DRYRUN=1 HCLOUD_TOKEN=x BWS_ACCESS_TOKEN=y HCLOUD_SSH_KEY_NAME=k
out=$(bash scripts/ydev/remote-up.sh 2>&1 || true)
echo "$out" | grep -q "hcloud server create" || { echo "FAIL create: $out"; exit 1; }
echo "$out" | grep -q -- "--type ccx43" || { echo "FAIL type: $out"; exit 1; }
echo "$out" | grep -q -- "--label managed-by=ydev" || { echo "FAIL label: $out"; exit 1; }
echo "PASS test_remote_up"
