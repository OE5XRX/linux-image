#!/usr/bin/env bash
# Boot the OE5XRX qemux86-64 Yocto image locally.
#
# Now boots via OVMF (UEFI) + GRUB-EFI from the wic image, with full A/B
# rootfs layout matching the RPi production image.
#
# Usage:
#   ./run.sh                 # boot latest downloaded image
#   ./run.sh --fetch         # download latest successful build artifact first
#   ./run.sh --fetch <run-id>  # download a specific run id
#
# Network:
#   User-mode (SLIRP) networking. The guest gets 10.0.2.15, gateway 10.0.2.2.
#   Host → guest SSH forward on localhost:2222.
#   Outbound internet works out-of-the-box (guest → NAT → host → WAN).
#
# A/B boot testing:
#   Login via SSH, then use grub-editenv to manipulate boot state:
#     grub-editenv /boot/EFI/BOOT/grubenv list              # show current state
#     grub-editenv /boot/EFI/BOOT/grubenv set boot_part=b   # switch to slot B
#     grub-editenv /boot/EFI/BOOT/grubenv set upgrade_available=1  # enter trial
#     reboot                                                 # GRUB picks up changes
#
# Requirements:
#   qemu-system-x86_64, ovmf, gh (only for --fetch), member of group "kvm".

set -euo pipefail

REPO="OE5XRX/linux-image"
ARTIFACT_NAME="yocto-image-qemux86-64"
WORKDIR="$(cd "$(dirname "$0")" && pwd)"
SSH_PORT="${SSH_PORT:-2222}"
MEM="${MEM:-1024}"
CPUS="${CPUS:-2}"

fetch_artifact() {
    local run_id="${1:-}"
    if [ -z "${run_id}" ]; then
        echo "==> Finding latest successful build..."
        run_id=$(gh run list -R "${REPO}" --limit 30 --json databaseId,conclusion \
            --jq 'map(select(.conclusion=="success")) | .[0].databaseId // empty')
    fi
    if [ -z "${run_id}" ]; then
        echo "ERROR: no successful run found" >&2; exit 1
    fi
    echo "==> Downloading artifact from run ${run_id}..."
    rm -rf "${WORKDIR}/${ARTIFACT_NAME}"
    cd "${WORKDIR}"
    gh run download "${run_id}" -R "${REPO}" -n "${ARTIFACT_NAME}" -D "${ARTIFACT_NAME}"
}

# Parse args
if [ "${1:-}" = "--fetch" ]; then
    fetch_artifact "${2:-}"
fi

# Locate the wic image (new A/B layout) or fall back to rootfs.ext4 (legacy).
WIC=""
search_paths=("${WORKDIR}/${ARTIFACT_NAME}" "${WORKDIR}")
for d in "${search_paths[@]}"; do
    [ -d "$d" ] || continue
    WIC=$(find "$d" -maxdepth 2 -name '*.rootfs.wic' -print -quit 2>/dev/null)
    [ -n "${WIC}" ] && break
done

if [ -z "${WIC}" ]; then
    echo "ERROR: Could not find *.rootfs.wic" >&2
    echo "       Run: $0 --fetch" >&2
    exit 1
fi

# OVMF UEFI firmware — GRUB-EFI needs this to boot.
OVMF="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS_TEMPLATE="/usr/share/OVMF/OVMF_VARS_4M.fd"
if [ ! -f "${OVMF}" ]; then
    # Fallback paths for different distros.
    for p in /usr/share/OVMF/OVMF_CODE.fd /usr/share/qemu/OVMF.fd /usr/share/edk2-ovmf/OVMF_CODE.fd; do
        [ -f "$p" ] && OVMF="$p" && break
    done
fi
if [ ! -f "${OVMF}" ]; then
    echo "ERROR: OVMF firmware not found. Install: sudo apt install ovmf" >&2
    exit 1
fi

# OVMF_VARS needs a per-VM writable copy (stores UEFI boot variables).
OVMF_VARS="${WORKDIR}/ovmf-vars.fd"
if [ ! -f "${OVMF_VARS}" ]; then
    for p in "${OVMF_VARS_TEMPLATE}" /usr/share/OVMF/OVMF_VARS.fd /usr/share/qemu/OVMF_VARS.fd; do
        if [ -f "$p" ]; then cp "$p" "${OVMF_VARS}"; break; fi
    done
fi
if [ ! -f "${OVMF_VARS}" ]; then
    echo "ERROR: OVMF_VARS template not found." >&2
    exit 1
fi

echo "==> WIC:    ${WIC}"
echo "==> OVMF:   ${OVMF}"
echo "==> SSH:    ssh -p ${SSH_PORT} root@localhost"
echo "==> Boot — Ctrl-A X to exit, or 'poweroff' inside guest"
echo "==> A/B:   grub-editenv /boot/EFI/BOOT/grubenv list"
echo

# Ensure KVM is accessible
if [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; then
    echo "WARNING: /dev/kvm not accessible — running without KVM (slow)." >&2
    KVM_FLAGS=""
else
    KVM_FLAGS="-enable-kvm"
fi

CPU_FLAGS="-cpu IvyBridge -machine q35"

exec qemu-system-x86_64 \
    ${KVM_FLAGS} \
    ${CPU_FLAGS} \
    -m "${MEM}" \
    -smp "${CPUS}" \
    -nographic \
    -serial mon:stdio \
    -drive if=pflash,format=raw,readonly=on,file="${OVMF}" \
    -drive if=pflash,format=raw,file="${OVMF_VARS}" \
    -drive file="${WIC}",if=virtio,format=raw \
    -device virtio-net-pci,netdev=n0 \
    -netdev user,id=n0,hostfwd=tcp::"${SSH_PORT}"-:22
