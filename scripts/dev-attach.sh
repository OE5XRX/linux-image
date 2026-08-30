#!/usr/bin/env bash
# Fast-Dev-Loop attach: mount the host's station_agent onto a RUNNING dev-image
# target, restart the agent, and follow its logs. Target-agnostic — works for a
# locally-booted QEMU (localhost:2222) and a real CM4 (LAN IP) alike. Booting the
# target is a separate step (`just local qemu --dev`, or a CM4 that is already up).
#   <device-host>  ssh target of the device (CM4 LAN IP, or localhost:2222 for QEMU)
#   <host-addr>    host address AS SEEN BY THE DEVICE (CM4: laptop LAN IP; QEMU: 10.0.2.2)
#   <repo-path>    absolute path of the station-manager repo on the host
set -euo pipefail
target="${1:?usage: dev-attach.sh <device-host[:port]> <host-addr> <repo-path>}"
host_addr="${2:?missing host-addr}"
repo="${3:?missing repo-path}"

here="$(cd "$(dirname "$0")" && pwd)"

# 1. Ensure the sshfs mount (dev-mount.sh handles the host:port -> ssh -p split).
"${here}/dev-mount.sh" "${target}" "${host_addr}" "${repo}"

# 2. Restart the agent and follow its logs. Split an optional :port for ssh, same
#    as dev-mount.sh — OpenSSH needs -p, not a "host:port" destination.
ssh_host="${target%%:*}"
ssh_opts=()
if [ "${target}" != "${ssh_host}" ]; then
    ssh_opts=(-p "${target##*:}")
fi
exec ssh "${ssh_opts[@]}" "root@${ssh_host}" \
    'systemctl restart station-agent && journalctl -u station-agent -f'
