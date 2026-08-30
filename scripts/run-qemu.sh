#!/usr/bin/env bash
# Boot the OE5XRX qemux86-64 Yocto image locally in QEMU.
#
# OVMF (UEFI) + GRUB-EFI boot from the wic, with the full A/B rootfs
# layout, matching the RPi production image as closely as possible.
#
# Usage:
#   scripts/run-qemu.sh                      boot image (auto-detect; errors if ambiguous)
#   scripts/run-qemu.sh --local              force the local Yocto build
#   scripts/run-qemu.sh --dist               force the remote-downloaded image (dist/)
#   scripts/run-qemu.sh --fetch              pull the latest CI artifact first
#   scripts/run-qemu.sh --fetch <run-id>     pull a specific GitHub Actions run
#   scripts/run-qemu.sh --release            pull the latest published release
#   scripts/run-qemu.sh --release <tag>      pull a specific release (e.g. v1-alpha)
#   scripts/run-qemu.sh --dev                boot the dev-image (live-mount the agent after)
#   scripts/run-qemu.sh -h | --help          this help
#
# Source flags select WHICH image; --dev selects the dev variant. They combine,
# e.g. `--dist --dev` boots the downloaded dev-image.
#
# Environment overrides:
#   SSH_PORT=2222    host port that maps to guest's sshd (default 2222)
#   MEM=1024         guest memory, MB (default 1024)
#   CPUS=2           guest CPU count (default 2)
#
# Image discovery order:
#   1. local Yocto build:  build/tmp/deploy/images/qemux86-64/*.rootfs.wic
#   2. remote download:    dist/qemux86-64/*.rootfs.wic  (just remote download)
#   3. CI artifact cache:  build/qemu-cache/yocto-image-qemux86-64/*.rootfs.wic
#   4. Release cache:      build/qemu-cache/release-<tag>/oe5xrx-qemux86-64-<tag>.wic
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
DEV_AGENT="${DEV_AGENT:-0}"
SOURCE=""   # explicit image source (local|dist|artifact|release); empty = auto-detect

set_source() {  # enforce a single explicit source
    if [ -n "${SOURCE}" ] && [ "${SOURCE}" != "$1" ]; then
        echo "ERROR: pick one image source (--${SOURCE} vs --$1)." >&2
        exit 2
    fi
    SOURCE="$1"
}

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

    # Accept either the new timestamp tags (YYYY.MM.DD-HH[a-z]) or
    # legacy v* tags. Anything else is a typo that would otherwise
    # waste a `gh release download` round-trip before failing opaquely.
    if ! [[ "${tag}" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}[a-z]?$ ]] \
        && ! [[ "${tag}" =~ ^v[A-Za-z0-9._-]+$ ]]; then
        echo "ERROR: '${tag}' is not a valid release tag." >&2
        echo "Expected YYYY.MM.DD-HH or YYYY.MM.DD-HH[a-z], or legacy v*." >&2
        exit 1
    fi

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
        --local) set_source local; shift ;;
        --dist)  set_source dist;  shift ;;
        --fetch)
            set_source artifact
            fetch_artifact "${2:-}"
            # If a run-id was passed, skip it; otherwise leave other args alone.
            if [ -n "${2:-}" ] && [[ "${2}" =~ ^[0-9]+$ ]]; then
                shift 2
            else
                shift
            fi
            ;;
        --release)
            set_source release
            # Optional positional tag; anything starting with '-' is another flag.
            if [ -n "${2:-}" ] && [[ "${2}" != -* ]]; then
                fetch_release "${2}"
                shift 2
            else
                fetch_release ""
                shift
            fi
            ;;
        --dev-agent|--dev)
            DEV_AGENT=1
            echo "==> Dev-Agent-Modus: bootet das Dev-Image. In einem 2. Terminal andocken mit:" >&2
            echo "    just dev qemu   (bzw. just dev attach localhost:${SSH_PORT} 10.0.2.2 ${REPO_ROOT%/*}/station-manager)" >&2
            shift
            ;;
        -h|--help) usage 0 ;;
        *) echo "Unknown arg: $1" >&2; usage 2 ;;
    esac
done

# --- Locate the wic ---
# Sources, in listing order: local build, remote download (dist/), CI artifact
# (--fetch), release (--release). A source flag (--local/--dist/--fetch/--release)
# picks exactly one; with no flag we auto-detect but REFUSE TO GUESS when more
# than one source has a candidate — you disambiguate with a flag.
# --dev-agent narrows to the dev-image wic (the default excludes it), so prod and
# dev never shadow each other within a dir.
if [ "${DEV_AGENT}" -eq 1 ]; then
    WIC_FIND=( -name 'oe5xrx-remotestation-dev-image-*.rootfs.wic' )
    label="dev-image wic"
else
    WIC_FIND=( '(' -name '*.rootfs.wic' -o -name "${RELEASE_ASSET_GLOB}.wic" ')'
               -not -name 'oe5xrx-remotestation-dev-image-*' )
    label="wic"
fi

find_wic() {  # $1 = dir -> prints the first matching (variant-filtered) wic, or nothing
    local d="$1"
    [ -n "${d}" ] && [ -d "${d}" ] || return 0
    find "${d}" -maxdepth 2 "${WIC_FIND[@]}" \
        -not -name '*.bz2' -not -name '*.xz' -not -name '*.gz' \
        -print -quit 2>/dev/null || true
}

src_dir() {  # $1 = source name -> its directory
    case "$1" in
        local)    printf '%s' "${REPO_ROOT}/build/tmp/deploy/images/qemux86-64" ;;
        dist)     printf '%s' "${REPO_ROOT}/dist/qemux86-64" ;;
        artifact) printf '%s' "${ARTIFACT_DIR}" ;;
        release)  printf '%s' "${RELEASE_DIR}" ;;
    esac
}

WIC=""
if [ -n "${SOURCE}" ]; then
    # Explicit source: use exactly that one.
    WIC=$(find_wic "$(src_dir "${SOURCE}")")
    [ -n "${WIC}" ] || { echo "ERROR: no qemux86-64 ${label} in the --${SOURCE} source." >&2; exit 1; }
else
    # Auto-detect: gather candidates across all sources; refuse to guess if >1.
    found=""
    for name in local dist artifact release; do
        w=$(find_wic "$(src_dir "${name}")")
        if [ -n "${w}" ]; then
            found="${found} ${name}"
            [ -z "${WIC}" ] && WIC="${w}"
        fi
    done
    if [ "$(echo ${found} | wc -w)" -gt 1 ]; then
        echo "ERROR: multiple qemux86-64 ${label}s found (sources:${found})." >&2
        echo "Refusing to guess — pick one: --local | --dist | --fetch | --release" >&2
        exit 1
    fi
fi

if [ -z "${WIC}" ]; then
    if [ "${DEV_AGENT}" -eq 1 ]; then
        cat >&2 <<EOF
ERROR: no qemux86-64 dev-image wic found (oe5xrx-remotestation-dev-image-*.rootfs.wic).

--dev-agent needs the DEV image built (locally or on the box), e.g.:
    just local build --dev
    just remote build --dev && just remote download --dev
EOF
    else
        cat >&2 <<EOF
ERROR: no qemux86-64 wic found.

Options:
    kas build qemux86-64.yml       build it locally
    $0 --fetch                     pull the latest CI artifact
    $0 --release                   pull the latest published release
EOF
    fi
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
    CPU_FLAGS="-cpu IvyBridge -machine q35"
else
    # No KVM (e.g. a cloud build box): fall back to TCG software emulation.
    # -cpu IvyBridge under TCG makes OVMF crash with "#UD - Invalid Opcode";
    # -cpu max is TCG-safe and boots fine (just slow). Prefer `just remote
    # download` + local qemu on a KVM host for interactive work.
    echo "WARNING: /dev/kvm not accessible — running without KVM (TCG, slow)." >&2
    KVM_FLAGS=""
    CPU_FLAGS="-cpu max -machine q35"
fi

echo "==> WIC:    ${WIC}"
echo "==> OVMF:   ${OVMF}"
echo "==> Cache:  ${CACHE_DIR}"
echo "==> SSH:    ssh -p ${SSH_PORT} root@localhost"
echo "==> Exit:   Ctrl-A X  (or 'poweroff' inside the guest)"
echo

# -device i6300esb: emulates the same PCI watchdog the guest driver arms
#   (the legacy -watchdog shorthand was removed in QEMU 9+, so use -device);
# -action watchdog=reset: a hang resets the VM instead of pausing, mirroring
# the Proxmox production setup (see docs/operations/watchdog-and-boot-robustness.md).
# The i6300esb stays disarmed until the guest's i6300esb_wdt driver arms it,
# so this is safe on images that don't yet enable the watchdog.
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
    -netdev user,id=n0,hostfwd=tcp::"${SSH_PORT}"-:22 \
    -device i6300esb \
    -action watchdog=reset
