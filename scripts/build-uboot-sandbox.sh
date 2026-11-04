#!/usr/bin/env bash
# Build the U-Boot SANDBOX (host executable) used by the boot-script tests in
# tests/ota-integration/test_boot_sandbox.py (marker `sandbox`).
#
# Usage: scripts/build-uboot-sandbox.sh <output-dir>
#
# Result: <output-dir>/u-boot (sandbox binary) and <output-dir>/tools/mkimage;
# point UBOOT_SANDBOX=<output-dir> at it. Idempotent: an existing build of the
# same version + config is reused (exit 0 without rebuilding).
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
UBOOT_REPO="https://source.denx.de/u-boot/u-boot.git"

if [ "$#" -ne 1 ]; then
    echo "usage: $0 <output-dir>" >&2
    exit 2
fi
out="$1"
stamp="${out}/.oe5xrx-sandbox-stamp"
want="${UBOOT_VERSION} OF_LIBFDT_OVERLAY CMD_FDT CMD_EXT4 CMD_PART -EFI_CAPSULE_AUTHENTICATE NO_SDL"

if [ -x "${out}/u-boot" ] && [ -x "${out}/tools/mkimage" ] \
        && [ -f "${stamp}" ] && [ "$(cat "${stamp}")" = "${want}" ]; then
    echo "U-Boot sandbox ${UBOOT_VERSION} already built in ${out}"
    exit 0
fi

if [ ! -d "${out}/.git" ]; then
    rm -rf "${out}"
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "${UBOOT_VERSION}" "${UBOOT_REPO}" "${out}"
fi

cd "${out}"
# Refuse to build anything but the pinned tag (a reused dir could be stale).
actual="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
if [ "${actual}" != "${UBOOT_VERSION}" ]; then
    echo "error: ${out} is at '${actual:-unknown}', expected ${UBOOT_VERSION}" >&2
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
echo "U-Boot sandbox ${UBOOT_VERSION} built in ${out}"
