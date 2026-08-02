#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; export YDEV_ROOT="$tmp"
# no session -> hint
if err=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh 2>&1); then echo "FAIL should exit"; exit 1; fi
echo "$err" | grep -q "just remote up" || { echo "FAIL hint: $err"; exit 1; }
# with session -> dry-run rsync (excludes build/) + kas build as yocto
printf '1 1.2.3.4 t\n' > "$tmp/.ydev-session"
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh raspberrypi4-64 2>&1)
echo "$out" | grep -q "rsync" && echo "$out" | grep -q -- "--exclude" || { echo "FAIL rsync: $out"; exit 1; }
echo "$out" | grep -q -- "--filter=:- .gitignore" || { echo "FAIL gitignore filter (kas layers must be excluded): $out"; exit 1; }
echo "$out" | grep -q "kas build raspberrypi4-64.yml" || { echo "FAIL kas: $out"; exit 1; }
echo "PASS test_remote_build"
