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

# /etc/stationagent — bind-mount target for the station-agent config dir.
# (Named "stationagent" without a hyphen because systemd mount-unit file
# names must match the mount path and dashes in paths need to be escaped
# as \x2d — a readability footgun we avoid by not having a dash here.)
#
# On first boot, seed from the shipped default (from the read-only rootfs)
# if the overlay copy is empty. Later boots keep whatever the operator
# (or provisioning flow) has written.
AGENT_ETC="${DATA}/etc-overlay/stationagent"
mkdir -p "${AGENT_ETC}"
chmod 0755 "${AGENT_ETC}"

# One-time migration from the old dashed path (pre-rename). Idempotent:
# once the new dir has config.yml, subsequent boots do nothing. No-op
# on freshly provisioned stations where the old dir never existed.
OLD_AGENT_ETC="${DATA}/etc-overlay/station-agent"
if [ ! -f "${AGENT_ETC}/config.yml" ] && [ -f "${OLD_AGENT_ETC}/config.yml" ]; then
    mv "${OLD_AGENT_ETC}/config.yml" "${AGENT_ETC}/config.yml"
    chown 0:0 "${AGENT_ETC}/config.yml"
    chmod 0600 "${AGENT_ETC}/config.yml"
    # Guard the key move: don't clobber a key that was already provisioned
    # under the new path (e.g. partially migrated state).
    if [ -f "${OLD_AGENT_ETC}/device_key.pem" ] && [ ! -f "${AGENT_ETC}/device_key.pem" ]; then
        mv "${OLD_AGENT_ETC}/device_key.pem" "${AGENT_ETC}/device_key.pem"
        chown 0:0 "${AGENT_ETC}/device_key.pem"
        chmod 0600 "${AGENT_ETC}/device_key.pem"
    fi
    rmdir "${OLD_AGENT_ETC}" 2>/dev/null || true
fi

if [ ! -f "${AGENT_ETC}/config.yml" ] && [ -f /etc/stationagent/config.yml ]; then
    cp /etc/stationagent/config.yml "${AGENT_ETC}/config.yml"
    chmod 0600 "${AGENT_ETC}/config.yml"
fi

exit 0
