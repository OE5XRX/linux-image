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

python stamp_release() {
    # Python so we don't have to worry about sed-special chars in the
    # tag (tags come from git refs — reasonably constrained, but still),
    # and so rewriting an existing OE5XRX_RELEASE line on a rebuild is
    # trivial instead of risking duplicate keys in /etc/os-release.
    import os

    rootfs = d.getVar('IMAGE_ROOTFS')
    tag = d.getVar('OE5XRX_RELEASE_TAG') or 'dev'

    etc_dir = os.path.join(rootfs, 'etc')
    os.makedirs(etc_dir, exist_ok=True)

    # /etc/issue — console banner. \r, \m, \l are getty escape codes for
    # kernel release / machine / terminal line. Kept as literal
    # backslash-letter pairs for getty to expand at login time.
    with open(os.path.join(etc_dir, 'issue'), 'w') as f:
        f.write(f"OE5XRX Remote Station {tag}\n")
        f.write("Kernel \\r on an \\m (\\l)\n\n")

    # /etc/os-release — replace Poky defaults in-place, then ensure the
    # OE5XRX_RELEASE field is set exactly once.
    os_release = os.path.join(etc_dir, 'os-release')
    if not os.path.exists(os_release):
        return

    overrides = {
        'PRETTY_NAME': f'OE5XRX Remote Station {tag}',
        'VERSION': tag,
        'VERSION_ID': tag,
        'OE5XRX_RELEASE': tag,
    }

    with open(os_release) as f:
        lines = f.readlines()

    seen = set()
    out = []
    for line in lines:
        replaced = False
        for key, value in overrides.items():
            if line.startswith(key + '='):
                out.append(f'{key}="{value}"\n')
                seen.add(key)
                replaced = True
                break
        if not replaced:
            out.append(line)

    for key, value in overrides.items():
        if key not in seen:
            out.append(f'{key}="{value}"\n')

    with open(os_release, 'w') as f:
        f.writelines(out)
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
