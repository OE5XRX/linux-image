#!/bin/sh
# First-boot initializer for the persistent data partition.
#
# Runs after /mnt/data is mounted, before var/home/root bind mounts.
# Idempotent: safe to run on every boot.
#
# Partition-grow logic intentionally lives in a separate data-grow.service
# (run once, behind a sentinel) because on QEMU the GPT backup header can
# be misplaced and parted hangs trying to "fix" it. Separating grow from
# this service keeps boot robust even if grow fails.

set -eu

DATA=/mnt/data

# Create top-level structure if missing.
mkdir -p \
    "${DATA}/var" \
    "${DATA}/home" \
    "${DATA}/root" \
    "${DATA}/etc-overlay/upper" \
    "${DATA}/etc-overlay/work"

# /var subtree — systemd/journald/apps expect these.
for d in log lib lib/systemd lib/dbus lib/station-agent lib/station-agent/downloads cache spool tmp local backups; do
    mkdir -p "${DATA}/var/${d}"
done

chmod 0700 "${DATA}/root"
chown 0:0 "${DATA}/root"
chmod 0755 "${DATA}/etc-overlay/upper" "${DATA}/etc-overlay/work"

# /etc/station-agent — bind-mount target for the station-agent config dir.
# On first boot, seed from the shipped default (from the read-only rootfs)
# if the overlay copy is empty. Later boots keep whatever the operator
# (or provisioning flow) has written.
AGENT_ETC="${DATA}/etc-overlay/station-agent"
mkdir -p "${AGENT_ETC}"
chmod 0755 "${AGENT_ETC}"
if [ ! -f "${AGENT_ETC}/config.yml" ] && [ -f /etc/station-agent/config.yml ]; then
    cp /etc/station-agent/config.yml "${AGENT_ETC}/config.yml"
    chmod 0600 "${AGENT_ETC}/config.yml"
fi

exit 0
