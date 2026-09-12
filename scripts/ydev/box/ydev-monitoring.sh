#!/usr/bin/env bash
set -euo pipefail
ALLOY_VERSION="v1.19.2"   # verify current-stable; Renovate/lockfile-bump tracks
install -d -m700 /etc/ydev
# config + unit are written by the caller (base64) to /etc/ydev/alloy.alloy and
# /etc/systemd/system/ydev-alloy.service; /etc/ydev/monitoring.env holds the env.
for _ in 1 2 3 4 5; do
  curl -fsSL "https://github.com/grafana/alloy/releases/download/${ALLOY_VERSION}/alloy-linux-amd64.zip" -o /tmp/alloy.zip && break || sleep 5
done
[ -s /tmp/alloy.zip ] || { echo "ydev: alloy download failed after 5 attempts" >&2; exit 1; }
( cd /tmp && unzip -o alloy.zip && install -m755 alloy-linux-amd64 /usr/local/bin/alloy )
systemctl daemon-reload
systemctl enable --now ydev-alloy.service
