#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export YDEV_ROOT="$tmp"
# no session -> require_session hint
if err=$( (. scripts/ydev/remote-lib.sh; require_session) 2>&1 ); then echo "FAIL require_session"; exit 1; fi
echo "$err" | grep -q "just remote up" || { echo "FAIL session hint: $err"; exit 1; }
# with fake session -> id/ip parse
printf '12345 1.2.3.4 2026-08-02T00:00:00Z\n' > "$tmp/.ydev-session"
out=$( . scripts/ydev/remote-lib.sh; echo "$(session_id)/$(session_ip)" )
[ "$out" = "12345/1.2.3.4" ] || { echo "FAIL parse: $out"; exit 1; }
# clean uses the strict label selector
out=$(YDEV_DRYRUN=1 HCLOUD_TOKEN=x bash scripts/ydev/remote-clean.sh 2>&1 || true)
echo "$out" | grep -q "managed-by==ydev" || { echo "FAIL clean label: $out"; exit 1; }
# down deletes the session id
out=$(YDEV_DRYRUN=1 HCLOUD_TOKEN=x bash scripts/ydev/remote-down.sh 2>&1 || true)
echo "$out" | grep -q "server delete" && echo "$out" | grep -q "12345" || { echo "FAIL down id: $out"; exit 1; }
echo "PASS test_remote_lib"
