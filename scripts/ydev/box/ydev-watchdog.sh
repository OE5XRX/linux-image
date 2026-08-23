#!/usr/bin/env bash
# Runs ON the ydev box via a systemd timer. Self-deletes the box when idle.
set -euo pipefail
STATE="${YDEV_STATE:-/var/lib/ydev/idle-since}"
IDLE_MIN="${YDEV_IDLE_MINUTES:-30}"
mkdir -p "$(dirname "$STATE")"
now=$(date +%s)
busy() {
  [ "${YDEV_TEST_BUSY:-}" = 1 ] && return 0
  [ "${YDEV_TEST_BUSY:-}" = 0 ] && return 1
  pgrep -x bitbake >/dev/null && return 0
  who | grep -q . && return 0            # any interactive login/ssh session
  ss -tnH state established '( sport = :ssh )' 2>/dev/null | grep -q . && return 0
  return 1
}
del() {
  id="${YDEV_SELF_ID:-$(curl -s http://169.254.169.254/hetzner/v1/metadata/instance-id)}"
  export HCLOUD_TOKEN="${HCLOUD_TOKEN:-$(cat /etc/ydev/token 2>/dev/null || true)}"
  if [ "${YDEV_DRYRUN:-0}" = 1 ]; then echo "DRYRUN: hcloud server delete $id"; return 0; fi
  # self-heal: if cloud-init's hcloud install didn't land (e.g. transient GitHub
  # outage at boot), install it now so THIS or a later timer run can still delete.
  command -v hcloud >/dev/null 2>&1 || curl -fsSL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz -C /usr/local/bin hcloud
  hcloud server delete "$id"
}
if busy; then echo "busy/active — reset idle timer"; echo "$now" > "$STATE"; exit 0; fi
[ -f "$STATE" ] || echo "$now" > "$STATE"
idle_since=$(cat "$STATE"); idle_min=$(( (now - idle_since) / 60 ))
echo "idle ${idle_min}m / ${IDLE_MIN}m"
[ "$idle_min" -ge "$IDLE_MIN" ] && { echo "idle threshold reached — self-deleting"; del; }
