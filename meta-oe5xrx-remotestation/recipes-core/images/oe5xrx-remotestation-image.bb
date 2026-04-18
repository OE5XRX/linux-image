SUMMARY = "OE5XRX Remote Station Image"
DESCRIPTION = "Production image for OE5XRX remote amateur radio stations"
LICENSE = "MIT"

inherit core-image

# ---- Base packages (all machines) ------------------------------------------

IMAGE_INSTALL = " \
    packagegroup-core-boot \
    python3 \
    htop \
    i2c-tools \
    station-agent \
    ab-layout \
"

# ---- Read-only rootfs + overlayfs-etc (all machines) -----------------------

IMAGE_FEATURES += " \
    ssh-server-openssh \
    read-only-rootfs \
    read-only-rootfs-delayed-postinsts \
"

IMAGE_CLASSES += "overlayfs-etc"
OVERLAYFS_ETC_MOUNT_POINT = "/mnt/data"
OVERLAYFS_ETC_FSTYPE = "ext4"
OVERLAYFS_ETC_DEVICE = "/dev/disk/by-partlabel/data"
OVERLAYFS_ETC_USE_ORIG_INIT_NAME = "1"
OVERLAYFS_ETC_EXPOSE_LOWER = "1"

# A/B wic layout — machine-specific wks + IMAGE_FSTYPES.
IMAGE_FSTYPES:append = " wic wic.bz2"

# ---- x86-64: GRUB-EFI A/B -------------------------------------------------

IMAGE_INSTALL:append:qemux86-64 = " grub-ab grub-efi"
WKS_FILE:qemux86-64 = "oe5xrx-remotestation-ab-x64.wks.in"
# grubenv must be on the ESP for load_env/save_env. grub-ab deploys it to
# DEPLOY_DIR_IMAGE; IMAGE_EFI_BOOT_FILES tells wic to copy it onto the ESP.
IMAGE_EFI_BOOT_FILES:append:qemux86-64 = " grubenv;EFI/BOOT/grubenv"
WKS_FILE_DEPENDS:append:qemux86-64 = " grub-ab"

# ---- Raspberry Pi: U-Boot A/B ----------------------------------------------

IMAGE_INSTALL:append:raspberrypi4-64 = " u-boot-ab u-boot-fw-utils"
WKS_FILE:raspberrypi4-64 = "oe5xrx-remotestation-ab.wks.in"

# meta-raspberrypi writes /dev/mmcblk0p1 in fstab for /boot/firmware. Our
# boot-firmware.mount in /etc/systemd/system/ overrides it with PARTLABEL,
# so this is harmless but worth noting.

# ---- Station agent dirs ---------------------------------------------------

create_agent_dirs() {
    install -d ${IMAGE_ROOTFS}/etc/stationagent
}
ROOTFS_POSTPROCESS_COMMAND += "create_agent_dirs;"

# ---- Release branding -----------------------------------------------------
# OE5XRX_RELEASE_TAG comes from the release workflow (e.g. "v1-beta") via
# BB_ENV_PASSTHROUGH_ADDITIONS in oe5xrx.yml, or defaults to "dev" for local
# builds. The station agent reads PRETTY_NAME from /etc/os-release for its
# heartbeat's os_version field, so replacing the Yocto/Poky defaults here
# surfaces the release in the web UI.
OE5XRX_RELEASE_TAG ??= "dev"

stamp_release() {
    install -d ${IMAGE_ROOTFS}/etc

    # Bitbake expands ${OE5XRX_RELEASE_TAG} at recipe-parse time before
    # handing this function to /bin/sh, so quoting-vs-expansion is a
    # non-issue. Landing the tag in a shell variable up-front makes that
    # explicit (readers don't have to reason about which ${} is bitbake
    # and which is shell) and lets us pick a pipe-safe sed delimiter.
    TAG="${OE5XRX_RELEASE_TAG}"
    ROOTFS="${IMAGE_ROOTFS}"

    cat > "${ROOTFS}/etc/issue" <<EOF
OE5XRX Remote Station ${TAG}
Kernel \r on an \m (\l)

EOF

    if [ -f "${ROOTFS}/etc/os-release" ]; then
        sed -i \
            -e "s|^PRETTY_NAME=.*|PRETTY_NAME=\"OE5XRX Remote Station ${TAG}\"|" \
            -e "s|^VERSION=.*|VERSION=\"${TAG}\"|" \
            -e "s|^VERSION_ID=.*|VERSION_ID=\"${TAG}\"|" \
            "${ROOTFS}/etc/os-release"
        # Additional field for consumers that want the raw tag without
        # the "OE5XRX Remote Station " prefix stripping ceremony.
        echo "OE5XRX_RELEASE=\"${TAG}\"" >> "${ROOTFS}/etc/os-release"
    fi
}
ROOTFS_POSTPROCESS_COMMAND += "stamp_release;"

# fstab fix for RPi: rewrite /dev/mmcblk0p1 -> PARTLABEL=firmware.
# (Belt-and-suspenders alongside the boot-firmware.mount override in ab-layout.)
python fix_firmware_fstab() {
    import os, re
    fstab = os.path.join(d.getVar('IMAGE_ROOTFS'), 'etc/fstab')
    if not os.path.exists(fstab):
        return
    with open(fstab) as f:
        content = f.read()
    new = re.sub(r'/dev/mmcblk0p1(\s+/boot/firmware)',
                 r'PARTLABEL=firmware\1', content)
    if new != content:
        with open(fstab, 'w') as f:
            f.write(new)
        bb.note('fix_firmware_fstab: rewrote mmcblk0p1 -> PARTLABEL=firmware')
}
ROOTFS_POSTPROCESS_COMMAND += "fix_firmware_fstab;"
