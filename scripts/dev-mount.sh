#!/usr/bin/env bash
# Mountet das Host-Repo per sshfs aufs Gerät (Fast-Dev-Loop, Tier 0).
# Das GERÄT ist sshfs-Client und verbindet zurück zum Host (Host braucht sshd).
#   <device-host>  ssh-Ziel des Geräts (CM4-LAN-IP oder localhost:2222 für QEMU)
#   <host-addr>    Host-Adresse AUS SICHT DES GERÄTS (CM4: LAN-IP des Laptops; QEMU: 10.0.2.2)
#   <repo-path>    absoluter Pfad des station-manager-Repos auf dem Host
#   HOST_USER      env, default = $USER
set -euo pipefail
dev_host="${1:?usage: dev-mount.sh <device-host> <host-addr> <repo-path>}"
host_addr="${2:?missing host-addr}"
repo="${3:?missing repo-path}"
host_user="${HOST_USER:-$USER}"

# dev_host may be "host" (CM4 LAN IP) or "host:port" (QEMU, e.g. localhost:2222).
# OpenSSH treats a bare "host:port" as an invalid hostname — the port must go via
# -p, so split it out here.
dev_ssh_host="${dev_host%%:*}"
ssh_opts=()
if [ "${dev_host}" != "${dev_ssh_host}" ]; then
    ssh_opts=(-p "${dev_host##*:}")
fi

# The dev-image rootfs is read-only (inherited from prod), so the device-side
# sshfs can't write root's default known_hosts on first connect. Pin it to a
# tmpfs path (/run) so accept-new works instead of breaking the mount.
ssh "${ssh_opts[@]}" "root@${dev_ssh_host}" "mkdir -p /mnt/dev/station_agent && \
  if mountpoint -q /mnt/dev/station_agent; then echo 'already mounted'; else \
    sshfs -o reconnect,ServerAliveInterval=15,StrictHostKeyChecking=accept-new,UserKnownHostsFile=/run/dev-mount.known_hosts \
      \"${host_user}@${host_addr}:${repo}/station_agent\" \"/mnt/dev/station_agent\" && \
    echo 'mounted'; fi"
