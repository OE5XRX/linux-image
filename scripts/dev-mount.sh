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

ssh "root@${dev_host}" "mkdir -p /mnt/dev/station_agent && \
  if mountpoint -q /mnt/dev/station_agent; then echo 'already mounted'; else \
    sshfs -o reconnect,ServerAliveInterval=15,StrictHostKeyChecking=accept-new \
      \"${host_user}@${host_addr}:${repo}/station_agent\" \"/mnt/dev/station_agent\" && \
    echo 'mounted'; fi"
