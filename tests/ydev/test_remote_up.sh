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
# box name is parameterisable (CI passes a unique per-run name)
out2=$(YDEV_SESSION_NAME=ci-42-1-qemux86-64 bash scripts/ydev/remote-up.sh 2>&1 || true)
echo "$out2" | grep -q -- "--name ci-42-1-qemux86-64" || { echo "FAIL custom name: $out2"; exit 1; }
# default is still ydev-session when unset
echo "$out" | grep -q -- "--name ydev-session" || { echo "FAIL default name: $out"; exit 1; }
echo "$out" | grep -qi "R2" || { echo "FAIL R2 mention missing in dryrun: $out"; exit 1; }
# teardown must be baked into the cloud-init user-data (dump hook)
ud=$(YDEV_DUMP_USERDATA=1 bash scripts/ydev/remote-up.sh 2>&1 || true)
echo "$ud" | grep -q "systemctl enable --now ydev-idle.timer" || { echo "FAIL ud enable timer: $ud"; exit 1; }
echo "$ud" | grep -q "ydev-maxlife" || { echo "FAIL ud maxlife unit: $ud"; exit 1; }
echo "$ud" | grep -q "server delete" || { echo "FAIL ud self-delete: $ud"; exit 1; }
# the dump hook must NOT leak the real token (redacted for CI logs / test output)
echo "$ud" | grep -q "TESTTOKEN123" && { echo "FAIL token leaked in dump"; exit 1; }
echo "$ud" | grep -q "<REDACTED>" || { echo "FAIL token not redacted: $ud"; exit 1; }
# datacenter fallback: default tries fsn1 -> nbg1 -> hel1 (Falkenstein runs full)
echo "$out" | grep -q "fsn1 nbg1 hel1" || { echo "FAIL default location list: $out"; exit 1; }
# YDEV_LOCATIONS overrides the whole ordered list
outloc=$(YDEV_LOCATIONS="nbg1 hel1" bash scripts/ydev/remote-up.sh 2>&1 || true)
echo "$outloc" | grep -q "nbg1 hel1" || { echo "FAIL YDEV_LOCATIONS override: $outloc"; exit 1; }
echo "$outloc" | grep -q "fsn1" && { echo "FAIL YDEV_LOCATIONS should not include fsn1: $outloc"; exit 1; }
# YDEV_LOCATION pins a single location (back-compat)
outloc1=$(YDEV_LOCATION="hel1" bash scripts/ydev/remote-up.sh 2>&1 || true)
echo "$outloc1" | grep -q "hel1" || { echo "FAIL YDEV_LOCATION back-compat: $outloc1"; exit 1; }
echo "$outloc1" | grep -q "nbg1" && { echo "FAIL YDEV_LOCATION should be sole location: $outloc1"; exit 1; }
# no Storage Box wiring in the script (check by absence of mount path)
! grep -qF "mnt/" scripts/ydev/remote-up.sh || { echo "FAIL old mount path still present in remote-up.sh"; exit 1; }
# R2 cred provisioning is present
grep -q "R2_SSTATE_KEY" scripts/ydev/remote-up.sh || { echo "FAIL R2_SSTATE_KEY missing from remote-up.sh"; exit 1; }
grep -q "/etc/ydev/r2env" scripts/ydev/remote-up.sh || { echo "FAIL r2env path missing from remote-up.sh"; exit 1; }
echo "PASS test_remote_up"
