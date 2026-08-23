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
# ssh identity: HCLOUD_SSH_KEY threads -i + IdentitiesOnly into YDEV_SSH and ydev_rsh
args=$( . scripts/ydev/remote-lib.sh; HCLOUD_SSH_KEY=/tmp/k ydev_ssh_args; printf '%s ' "${YDEV_SSH[@]}" )
{ echo "$args" | grep -q -- "-i /tmp/k" && echo "$args" | grep -q "IdentitiesOnly=yes"; } || { echo "FAIL ssh id: $args"; exit 1; }
noargs=$( . scripts/ydev/remote-lib.sh; ydev_ssh_args; printf '%s ' "${YDEV_SSH[@]}" )
echo "$noargs" | grep -q -- "-i " && { echo "FAIL ssh id leak (no key set): $noargs"; exit 1; }
# ephemeral box: per-session known_hosts + accept-new (Hetzner recycles IPs, but
# still TOFU-pin within a session rather than blanket-trust every connection)
{ echo "$noargs" | grep -q "StrictHostKeyChecking=accept-new" && echo "$noargs" | grep -q "UserKnownHostsFile=.*\.ydev-known-hosts"; } || { echo "FAIL host-key policy: $noargs"; exit 1; }
rsh=$( t='~'; . scripts/ydev/remote-lib.sh; HCLOUD_SSH_KEY="$t/x" ydev_rsh )
echo "$rsh" | grep -q -- "-i ${HOME}/x" || { echo "FAIL rsh tilde expand: $rsh"; exit 1; }
echo "PASS test_remote_lib"
