#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmpkey="$(mktemp)"; tmproot="$(mktemp -d)"; trap 'rm -f "$tmpkey"; rm -rf "$tmproot"' EXIT
# Point YDEV_ROOT at a fresh dir with NO .env so load_env is a no-op and the
# vars exported below are authoritative (isolation without weakening the loader).
export YDEV_ROOT="$tmproot"
export STORAGE_BOX_HOST=u1.example STORAGE_BOX_USER=u1
# missing key -> must exit non-zero AND print the hint
if err=$(YDEV_DRYRUN=1 YDEV_KEY="$tmpkey.nope" bash scripts/ydev/local-mount.sh 2>&1); then echo "FAIL missing-key should exit nonzero: $err"; exit 1; fi
echo "$err" | grep -q "storagebox" || { echo "FAIL missing-key hint: $err"; exit 1; }
# with key -> dry-run prints an sshfs to the box HOME (host:) on port 23
out=$(YDEV_DRYRUN=1 YDEV_KEY="$tmpkey" YDEV_FORCE_MOUNTED=0 bash scripts/ydev/local-mount.sh 2>&1 || true)
echo "$out" | grep -q -- "-p 23" || { echo "FAIL port: $out"; exit 1; }
echo "$out" | grep -q "u1@u1.example:" || { echo "FAIL target host: $out"; exit 1; }
echo "$out" | grep -q "/mnt/yocto-shared" || { echo "FAIL mnt: $out"; exit 1; }
echo "PASS test_local_mount"
