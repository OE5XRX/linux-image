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
#   scripts/run-qemu.sh --release            pull the latest published release
#   scripts/run-qemu.sh --release <tag>      pull a specific release (e.g. v1-alpha)
#   scripts/run-qemu.sh -h | --help          this help
#
# Environment overrides:
#   SSH_PORT=2222    host port that maps to guest's sshd (default 2222)
#   MEM=1024         guest memory, MB (default 1024)
#   CPUS=2           guest CPU count (default 2)
#
# Image discovery order:
#   1. local Yocto build:  build/tmp/deploy/images/qemux86-64/*.rootfs.wic
#   2. CI artifact cache:  build/qemu-cache/yocto-image-qemux86-64/*.rootfs.wic
#   3. Release cache:      build/qemu-cache/release-<tag>/oe5xrx-qemux86-64-<tag>.wic
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
RELEASE_ASSET_GLOB="oe5xrx-qemux86-64-*"

# Resolve the repo root (script lives at <repo>/scripts/).
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# build/ is .gitignored — stash QEMU state there to keep the tree clean.
CACHE_DIR="${REPO_ROOT}/build/qemu-cache"
ARTIFACT_DIR="${CACHE_DIR}/${ARTIFACT_NAME}"
RELEASE_DIR=""   # set by fetch_release; also searched when locating the wic

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

fetch_release() {
    local tag="${1:-}"
    if [ -z "${tag}" ]; then
        echo "==> Finding latest release on ${REPO}..."
        tag=$(gh release list -R "${REPO}" --limit 1 \
            --json tagName --jq '.[0].tagName // empty')
    fi
    [ -n "${tag}" ] || { echo "ERROR: no release found" >&2; exit 1; }

    RELEASE_DIR="${CACHE_DIR}/release-${tag}"
    mkdir -p "${RELEASE_DIR}"

    local bz2 sha
    bz2=$(find "${RELEASE_DIR}" -maxdepth 1 -name '*.wic.bz2' -print -quit)
    sha="${bz2:-}${bz2:+.sha256}"

    # Cache hit: both archive and sidecar already on disk. Skip the download.
    if [ -n "${bz2}" ] && [ -f "${sha}" ]; then
        echo "==> Release ${tag} already cached, skipping download."
    else
        echo "==> Downloading release ${tag} (qemux86-64 assets)..."
        gh release download "${tag}" -R "${REPO}" \
            --pattern "${RELEASE_ASSET_GLOB}.wic.bz2" \
            --pattern "${RELEASE_ASSET_GLOB}.wic.bz2.sha256" \
            -D "${RELEASE_DIR}" --clobber
        bz2=$(find "${RELEASE_DIR}" -maxdepth 1 -name '*.wic.bz2' -print -quit)
        [ -n "${bz2}" ] || { echo "ERROR: release ${tag} has no qemux86-64 wic asset" >&2; exit 1; }
        sha="${bz2}.sha256"
    fi

    # Always verify — release.yml publishes the sidecar for every asset, so
    # a missing .sha256 means something is wrong. Refuse to boot unverified.
    [ -f "${sha}" ] || { echo "ERROR: missing ${sha} — refusing to boot unverified image" >&2; exit 1; }
    echo "==> Verifying sha256..."
    (cd "${RELEASE_DIR}" && sha256sum -c "$(basename "${sha}")")

    # Decompress once, but to a temp file first so an interrupted run
    # can't leave a partial .wic that a later run would silently reuse.
    local wic="${bz2%.bz2}"
    if [ ! -f "${wic}" ]; then
        echo "==> Decompressing $(basename "${bz2}")..."
        bzip2 -dkc "${bz2}" > "${wic}.tmp"
        mv "${wic}.tmp" "${wic}"
    fi
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
        --release)
            # Optional positional tag; anything starting with '-' is another flag.
            if [ -n "${2:-}" ] && [[ "${2}" != -* ]]; then
                fetch_release "${2}"
                shift 2
            else
                fetch_release ""
                shift
            fi
            ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown arg: $1" >&2; usage 2 ;;
    esac
done

# --- Locate the wic ---
# Accept both the Yocto-native name (*.rootfs.wic, from local builds and CI
# artifacts) and the release-asset name (oe5xrx-qemux86-64-<tag>.wic).
WIC=""
for search_dir in \
    "${REPO_ROOT}/build/tmp/deploy/images/qemux86-64" \
    "${ARTIFACT_DIR}" \
    "${RELEASE_DIR}"; do
    [ -n "${search_dir}" ] && [ -d "${search_dir}" ] || continue
    WIC=$(find "${search_dir}" -maxdepth 2 \
        \( -name '*.rootfs.wic' -o -name "${RELEASE_ASSET_GLOB}.wic" \) \
        -not -name '*.bz2' -not -name '*.xz' -not -name '*.gz' \
        -print -quit 2>/dev/null || true)
    [ -n "${WIC}" ] && break
done

if [ -z "${WIC}" ]; then
    cat >&2 <<EOF
ERROR: no qemux86-64 wic found.

Options:
    kas build qemux86-64.yml       build it locally
    $0 --fetch                     pull the latest CI artifact
    $0 --release                   pull the latest published release
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
