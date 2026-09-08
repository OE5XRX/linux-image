#!/bin/sh
# Grow the persistent data partition to fill the block device.
#
# Runs at boot BEFORE /mnt/data is mounted, so the grow is fully offline
# (no online-resize of a mounted partition, no partprobe-on-mounted-disk
# problem). NO sentinel: it is idempotent and free-space-gated, so it also
# handles "resize the medium later" flows — e.g. a Proxmox `qm resize` or
# reflashing onto a larger eMMC/SD after the first boot. When there is no
# free space after `data` (the wic booted at its own size), it is a cheap
# no-op that never touches parted/e2fsck/resize2fs.
#
# ROBUST-FAIL: any failure exits 0 so a grow problem never blocks boot;
# data-init then mounts /mnt/data at whatever size it currently is.
#
# Device/partnum are derived from the `data` PARTLABEL, so this works on
# mmcblk0 (rpi), vda (QEMU virtio) and sda/vda/nvme (Proxmox, any bus).
set -u

MARGIN=4096   # sectors (~2 MiB). Ignore the GPT-backup tail / trivial slack.

# Wait for udev to create the by-partlabel symlink (we run early at boot).
DATA_DEV=""
i=0
while [ "$i" -lt 50 ]; do
    DATA_DEV="$(readlink -f /dev/disk/by-partlabel/data 2>/dev/null || true)"
    [ -b "$DATA_DEV" ] && break
    udevadm settle --timeout=2 2>/dev/null || sleep 0.2
    i=$((i + 1))
done
[ -b "$DATA_DEV" ] || { echo "data-grow: /dev/disk/by-partlabel/data not present — skip"; exit 0; }

BASE="$(basename "$DATA_DEV")"
PK="$(lsblk -no PKNAME "$DATA_DEV" 2>/dev/null)"
DISK="/dev/${PK}"
PARTNUM="$(cat "/sys/class/block/${BASE}/partition" 2>/dev/null)"
if [ -z "$PK" ] || [ -z "$PARTNUM" ] || [ ! -b "$DISK" ]; then
    echo "data-grow: could not resolve disk/partnum for $DATA_DEV — skip"
    exit 0
fi

# Free-space gate: only act if there are real unused sectors after `data`.
DISK_SECTORS="$(cat "/sys/block/${PK}/size" 2>/dev/null || echo 0)"
PART_START="$(cat "/sys/class/block/${BASE}/start" 2>/dev/null || echo 0)"
PART_SIZE="$(cat "/sys/class/block/${BASE}/size" 2>/dev/null || echo 0)"
PART_END=$((PART_START + PART_SIZE))
FREE=$((DISK_SECTORS - PART_END))
if [ "$DISK_SECTORS" -le 0 ] || [ "$FREE" -le "$MARGIN" ]; then
    echo "data-grow: no free space after data (free=${FREE} sectors) — nothing to do"
    exit 0
fi
echo "data-grow: ${FREE} free sectors after data on ${DISK} — growing"

# Relocate the GPT backup header to the end of the (now larger) device; after a
# resize/flash-onto-bigger-medium it sits mid-disk and parted would otherwise
# complain. timeout guards against any hang.
timeout 30 sgdisk -e "$DISK" || { echo "data-grow: sgdisk -e failed/timed out on $DISK"; exit 0; }

# Extend the data partition to the end of the disk (script mode, never prompts).
timeout 30 parted -s "$DISK" resizepart "$PARTNUM" 100% || { echo "data-grow: resizepart failed on $DISK:$PARTNUM"; exit 0; }
partprobe "$DISK" 2>/dev/null || true

# Filesystem is unmounted here: fsck then offline-grow it into the new space.
timeout 300 e2fsck -pf "$DATA_DEV"; rc=$?
if [ "$rc" -ge 4 ]; then echo "data-grow: e2fsck rc=$rc on $DATA_DEV — skip resize"; exit 0; fi
timeout 300 resize2fs "$DATA_DEV" || { echo "data-grow: resize2fs failed on $DATA_DEV"; exit 0; }

echo "data-grow: grew $DATA_DEV to fill $DISK"
exit 0
