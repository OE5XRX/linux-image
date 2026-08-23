#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export YDEV_ROOT="$tmp" YDEV_DRYRUN=1 HCLOUD_TOKEN=TESTTOKEN123 BWS_ACCESS_TOKEN=y HCLOUD_SSH_KEY_NAME=k
out=$(bash scripts/ydev/remote-up.sh 2>&1 || true)
echo "$out" | grep -q "hcloud server create" || { echo "FAIL create: $out"; exit 1; }
echo "$out" | grep -q -- "--type ccx43" || { echo "FAIL type: $out"; exit 1; }
echo "$out" | grep -q -- "--label managed-by=ydev" || { echo "FAIL label: $out"; exit 1; }
echo "$out" | grep -q -- "--user-data-from-file" || { echo "FAIL user-data flag: $out"; exit 1; }
echo "$out" | grep -qi "cloud-init" || { echo "FAIL cloud-init note: $out"; exit 1; }
# teardown must be baked into the cloud-init user-data (dump hook)
ud=$(YDEV_DUMP_USERDATA=1 bash scripts/ydev/remote-up.sh 2>&1 || true)
echo "$ud" | grep -q "systemctl enable --now ydev-idle.timer" || { echo "FAIL ud enable timer: $ud"; exit 1; }
echo "$ud" | grep -q "ydev-maxlife" || { echo "FAIL ud maxlife unit: $ud"; exit 1; }
echo "$ud" | grep -q "server delete" || { echo "FAIL ud self-delete: $ud"; exit 1; }
# the dump hook must NOT leak the real token (redacted for CI logs / test output)
echo "$ud" | grep -q "TESTTOKEN123" && { echo "FAIL token leaked in dump"; exit 1; }
echo "$ud" | grep -q "<REDACTED>" || { echo "FAIL token not redacted: $ud"; exit 1; }
echo "PASS test_remote_up"
