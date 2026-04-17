#!/usr/bin/env bash
# Boot the OE5XRX qemux86-64 Yocto image locally in QEMU.
#
# OVMF (UEFI) + GRUB-EFI boot from the wic, with the full A/B rootfs
# layout, matching the RPi production image as closely as possible.
#
# Usage:
#   scripts/run-qemu.sh                      boot image from local build or cache
#   scripts/run-qemu.sh --fetch              pull the latest CI artifact first
#   scripts/run-qemu.sh --fetch <run-id>     pull a specific GitHub Actions run
#   scripts/run-qemu.sh -h | --help          this help
#
# Environment overrides:
#   SSH_PORT=2222    host port that maps to guest's sshd (default 2222)
#   MEM=1024         guest memory, MB (default 1024)
#   CPUS=2           guest CPU count (default 2)
#
# Image discovery order:
#   1. local Yocto build: build/tmp/deploy/images/qemux86-64/*.rootfs.wic
#   2. CI artifact cache: build/qemu-cache/yocto-image-qemux86-64/*.rootfs.wic
#
# A/B boot testing (from inside the guest):
#   grub-editenv /boot/EFI/BOOT/grubenv list
#   grub-editenv /boot/EFI/BOOT/grubenv set boot_part=b upgrade_available=1 bootcount=0
#   reboot          # GRUB will roll back to slot A after 3 failed attempts
#
# Host requirements:
#   Debian/Ubuntu: sudo apt install qemu-system-x86 ovmf
#                  sudo usermod -aG kvm "$USER"  (log out+in)
#   Fedora:        sudo dnf install qemu-system-x86 edk2-ovmf
#   Arch:          sudo pacman -S qemu-system-x86 edk2-ovmf
#
#   Plus `gh` (GitHub CLI, https://cli.github.com) if you use --fetch.

set -euo pipefail

REPO="OE5XRX/linux-image"
ARTIFACT_NAME="yocto-image-qemux86-64"

# Resolve the repo root (script lives at <repo>/scripts/).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# build/ is .gitignored — stash QEMU state there to keep the tree clean.
CACHE_DIR="${REPO_ROOT}/build/qemu-cache"
ARTIFACT_DIR="${CACHE_DIR}/${ARTIFACT_NAME}"

SSH_PORT="${SSH_PORT:-2222}"
MEM="${MEM:-1024}"
CPUS="${CPUS:-2}"

usage() {
    sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

fetch_artifact() {
    local run_id="${1:-}"
    if [ -z "${run_id}" ]; then
        echo "==> Finding latest successful build on ${REPO}..."
        run_id=$(gh run list -R "${REPO}" --limit 30 \
            --workflow 'Build Yocto Image' \
            --json databaseId,conclusion \
            --jq 'map(select(.conclusion=="success")) | .[0].databaseId // empty')
    fi
    [ -n "${run_id}" ] || { echo "ERROR: no successful run found" >&2; exit 1; }

    echo "==> Downloading artifact from run ${run_id}..."
    mkdir -p "${CACHE_DIR}"
    rm -rf "${ARTIFACT_DIR}"
    gh run download "${run_id}" -R "${REPO}" -n "${ARTIFACT_NAME}" -D "${ARTIFACT_DIR}"
}

# --- Arg parsing ---
while [ $# -gt 0 ]; do
    case "$1" in
        --fetch)
            fetch_artifact "${2:-}"
            # If a run-id was passed, skip it; otherwise leave other args alone.
            if [ -n "${2:-}" ] && [[ "${2}" =~ ^[0-9]+$ ]]; then
                shift 2
            else
                shift
            fi
            ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown arg: $1" >&2; usage 2 ;;
    esac
done

# --- Locate the wic ---
WIC=""
for search_dir in \
    "${REPO_ROOT}/build/tmp/deploy/images/qemux86-64" \
    "${ARTIFACT_DIR}"; do
    [ -d "${search_dir}" ] || continue
    WIC=$(find "${search_dir}" -maxdepth 2 -name '*.rootfs.wic' -print -quit 2>/dev/null || true)
    [ -n "${WIC}" ] && break
done

if [ -z "${WIC}" ]; then
    cat >&2 <<EOF
ERROR: no *.rootfs.wic found.

Either build locally with:
    kas build qemux86-64.yml

Or pull the latest CI artifact:
    $0 --fetch
EOF
    exit 1
fi

# --- Locate OVMF UEFI firmware ---
OVMF=""
for p in \
    /usr/share/OVMF/OVMF_CODE_4M.fd \
    /usr/share/OVMF/OVMF_CODE.fd \
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
    /usr/share/edk2/ovmf/OVMF_CODE.fd \
    /usr/share/qemu/OVMF.fd; do
    [ -f "$p" ] && OVMF="$p" && break
done
if [ -z "${OVMF}" ]; then
    echo "ERROR: OVMF firmware not found. Install 'ovmf' / 'edk2-ovmf'." >&2
    exit 1
fi

OVMF_VARS="${CACHE_DIR}/ovmf-vars.fd"
mkdir -p "${CACHE_DIR}"
if [ ! -f "${OVMF_VARS}" ]; then
    for p in \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/qemu/OVMF_VARS.fd; do
        if [ -f "$p" ]; then cp "$p" "${OVMF_VARS}"; break; fi
    done
fi
if [ ! -f "${OVMF_VARS}" ]; then
    echo "ERROR: OVMF_VARS template not found." >&2
    exit 1
fi

# --- KVM acceleration (optional) ---
if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    KVM_FLAGS="-enable-kvm"
else
    echo "WARNING: /dev/kvm not accessible — running without KVM (slow)." >&2
    KVM_FLAGS=""
fi
CPU_FLAGS="-cpu IvyBridge -machine q35"

echo "==> WIC:    ${WIC}"
echo "==> OVMF:   ${OVMF}"
echo "==> Cache:  ${CACHE_DIR}"
echo "==> SSH:    ssh -p ${SSH_PORT} root@localhost"
echo "==> Exit:   Ctrl-A X  (or 'poweroff' inside the guest)"
echo

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
