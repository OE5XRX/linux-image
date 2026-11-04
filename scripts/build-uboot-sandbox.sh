#!/usr/bin/env bash
# Build the U-Boot SANDBOX (host executable) used by the boot-script tests in
# tests/ota-integration/test_boot_sandbox.py (marker `sandbox`).
#
# Usage: scripts/build-uboot-sandbox.sh <output-dir>
#
# Result: <output-dir>/u-boot (sandbox binary) and <output-dir>/tools/mkimage;
# point UBOOT_SANDBOX=<output-dir> at it. Idempotent: an existing build of the
# same version + commit + config is reused (exit 0 without rebuilding). The
# stamp <output-dir>/.oe5xrx-sandbox-stamp records version, commit SHA and
# config; u-boot + tools/mkimage + the stamp are all the tests need (the
# sandbox runs without -d/-D, i.e. without u-boot.dtb), so a CI cache holding
# only those three files counts as built.
#
# The version MUST match the U-Boot the rpi image ships (v2026.01) so the hush
# shell and the fdt/ext4/part commands behave like on the CM4. Config =
# sandbox_defconfig + OF_LIBFDT_OVERLAY CMD_FDT CMD_EXT4 CMD_PART, with
# EFI_CAPSULE_AUTHENTICATE disabled (otherwise the build needs an EFI signing
# tool). NO_SDL=1: no display needed.
#
# Build deps (Debian/Ubuntu): build-essential bison flex libssl-dev
# libgnutls28-dev uuid-dev python3-dev python3-setuptools swig pkg-config bc git
set -euo pipefail

UBOOT_VERSION="v2026.01"
# Peeled commit of the tag (a moved tag must not change what we test):
#   git ls-remote https://source.denx.de/u-boot/u-boot.git 'refs/tags/v2026.01^{}'
UBOOT_SHA="127a42c7257a6ffbbd1575ed1cbaa8f5408a44b3"
UBOOT_REPO="https://source.denx.de/u-boot/u-boot.git"

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <output-dir>" >&2
    exit 2
fi
# Absolute: the build below runs after `cd "${out}"`, so a relative path
# would put the stamp in the wrong place.
out="$(realpath -m -- "$1")"
stamp="${out}/.oe5xrx-sandbox-stamp"
want="${UBOOT_VERSION} ${UBOOT_SHA} OF_LIBFDT_OVERLAY CMD_FDT CMD_EXT4 CMD_PART -EFI_CAPSULE_AUTHENTICATE NO_SDL"

head_sha() {
    git -C "$1" rev-parse --verify --quiet 'HEAD^{commit}' || true
}

# Reuse: binaries + matching stamp (records the SHA). A minimal cache has no
# .git; if the source tree is there, it must still be at the pinned commit.
if [ -x "${out}/u-boot" ] && [ -x "${out}/tools/mkimage" ] \
        && [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${want}" ] \
        && { [ ! -e "${out}/.git" ] || [ "$(head_sha "${out}")" = "${UBOOT_SHA}" ]; }; then
    echo "U-Boot sandbox ${UBOOT_VERSION} (${UBOOT_SHA}) already built in ${out}"
    exit 0
fi

# True if ${out} may be deleted for a fresh clone: absent, empty, or holding
# only our cache set (u-boot, tools/mkimage, stamp). Never wipe anything else.
replaceable() {
    local entry
    [ -e "${out}" ] || return 0
    [ -d "${out}" ] || return 1
    while IFS= read -r -d '' entry; do
        case "${entry#"${out}"/}" in
            u-boot | tools | tools/mkimage | .oe5xrx-sandbox-stamp) ;;
            *) return 1 ;;
        esac
    done < <(find "${out}" -mindepth 1 -print0)
}

if [ ! -d "${out}/.git" ]; then
    if ! replaceable; then
        echo "error: ${out} exists and is neither empty, a U-Boot clone nor a sandbox cache (u-boot, tools/mkimage, .oe5xrx-sandbox-stamp); refusing to delete it" >&2
        exit 1
    fi
    rm -rf "${out}"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${UBOOT_VERSION}" "${UBOOT_REPO}" "${out}"
fi

cd "${out}"
# Refuse to build anything but the pinned commit (a reused dir could be
# stale, a re-pointed tag would be a different U-Boot).
actual="$(head_sha .)"
if [ "${actual}" != "${UBOOT_SHA}" ]; then
    echo "error: ${out} is at '${actual:-unknown}', expected ${UBOOT_VERSION} = ${UBOOT_SHA}" >&2
    exit 1
fi

make -s sandbox_defconfig
./scripts/config \
    --enable OF_LIBFDT_OVERLAY \
    --enable CMD_FDT \
    --enable CMD_EXT4 \
    --enable CMD_PART \
    --disable EFI_CAPSULE_AUTHENTICATE
make -s olddefconfig

# Fail loudly if olddefconfig dropped a required option.
for opt in OF_LIBFDT_OVERLAY CMD_FDT CMD_EXT4 CMD_PART CMD_POWEROFF; do
    grep -qx "CONFIG_${opt}=y" .config || {
        echo "error: CONFIG_${opt} not enabled in .config" >&2
        exit 1
    }
done

make -s NO_SDL=1 -j"$(nproc)"

test -x u-boot
test -x tools/mkimage
echo "${want}" > "${stamp}"
echo "U-Boot sandbox ${UBOOT_VERSION} (${UBOOT_SHA}) built in ${out}"
