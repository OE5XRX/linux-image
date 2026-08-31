#!/usr/bin/env bash
# Fast-Dev-Loop attach: sshfs-mount the host's station_agent onto a RUNNING
# dev-image target, restart the agent, and follow its logs. Target-agnostic —
# works for a locally-booted QEMU (localhost:2222) and a real CM4 (LAN IP) alike.
# Booting the target is a separate step (`just local qemu --dev`, or a CM4 that
# is already up).
#   <device-host>  ssh target of the device (CM4 LAN IP, or localhost:2222 for QEMU)
#   <host-addr>    host address AS SEEN BY THE DEVICE (CM4: laptop LAN IP; QEMU: 10.0.2.2)
#   <repo-path>    absolute path of the station-manager repo on the host
#   HOST_USER      env, default = $USER
set -euo pipefail
target="${1:?usage: dev-attach.sh <device-host[:port]> <host-addr> <repo-path>}"
host_addr="${2:?missing host-addr}"
repo="${3:?missing repo-path}"
host_user="${HOST_USER:-$USER}"

# Split an optional :port once — OpenSSH needs -p, not a "host:port" destination
# (QEMU forwards the guest sshd to localhost:2222). Reused for both ssh calls.
ssh_host="${target%%:*}"
ssh_opts=()
if [ "${target}" != "${ssh_host}" ]; then
    ssh_opts=(-p "${target##*:}")
fi

# 1. Ensure the sshfs mount (idempotent). The mountpoint is baked by the dev
#    recipe (the rootfs is read-only); known_hosts is pinned to a tmpfs path
#    (/run) so accept-new works — root's /root/.ssh isn't writable.
ssh "${ssh_opts[@]}" "root@${ssh_host}" "mkdir -p /mnt/dev/station_agent && \
  if mountpoint -q /mnt/dev/station_agent; then echo 'already mounted'; else \
    sshfs -o reconnect,ServerAliveInterval=15,StrictHostKeyChecking=accept-new,UserKnownHostsFile=/run/station-agent-dev.known_hosts \
      \"${host_user}@${host_addr}:${repo}/station_agent\" \"/mnt/dev/station_agent\" && \
    echo 'mounted'; fi"

# 2. Restart the agent and follow its logs.
exec ssh "${ssh_opts[@]}" "root@${ssh_host}" \
    'systemctl restart station-agent && journalctl -u station-agent -f'
