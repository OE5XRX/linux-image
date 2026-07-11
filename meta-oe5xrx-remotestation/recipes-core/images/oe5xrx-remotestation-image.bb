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

# Kernel-in-rootfs A/B: the bootloader loads /boot/bzImage (x86) / /boot/Image
# (RPi) from the ACTIVE root_${slot}, so kernel + modules must live in the
# rootfs and travel with it through OTA (one artifact, atomic per slot).
# NOTE: the bootimg-efi wic plugin also copies bzImage onto the ESP; with this
# change that ESP copy is unused (grub.cfg loads from the rootfs), but it is
# left as harmless dead weight rather than fighting the plugin.
IMAGE_INSTALL:append = " kernel-image kernel-modules"

# bzip2 CLI is a convenience for manual debugging of downloaded .wic.bz2
# images on-device. The station-agent uses Python stdlib bz2 internally.
IMAGE_INSTALL:append = " bzip2"

# D2 slot contract: udev rules that map BusBoard hub ports to /dev/oe5xrx/slotN/control.
IMAGE_INSTALL:append = " oe5xrx-slot-udev oe5xrx-fm-firmware"

# Boot robustness: hung-task -> panic -> reboot -> A/B bootcount rollback.
# Pairs with cmdline panic=5 softlockup_panic=1 (set in grub.cfg / boot.cmd).
IMAGE_INSTALL:append = " oe5xrx-boot-robustness"

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

# Co-located module simulation stack (native_sim FM + sim-harness). The
# qemux86-64 image is the Proxmox/VM deployment, which has no real FM hardware,
# so the simulator IS the module — always built here. native_sim is x86-only
# (COMPATIBLE_MACHINE = "qemux86-64"), so it never reaches the RPi image.
IMAGE_INSTALL:append:qemux86-64 = " packagegroup-oe5xrx-sim"
WKS_FILE:qemux86-64 = "oe5xrx-remotestation-ab-x64.wks.in"
# grubenv must be on the ESP for load_env/save_env. grub-ab deploys it to
# DEPLOY_DIR_IMAGE; IMAGE_EFI_BOOT_FILES tells wic to copy it onto the ESP.
IMAGE_EFI_BOOT_FILES:append:qemux86-64 = " grubenv;EFI/BOOT/grubenv"
WKS_FILE_DEPENDS:append:qemux86-64 = " grub-ab"

# ---- Raspberry Pi: U-Boot A/B ----------------------------------------------

IMAGE_INSTALL:append:raspberrypi4-64 = " u-boot-ab u-boot-fw-utils"

# RPi: u-boot ext4load's /boot/Image + the CM4 dtb from the rootfs slot.
# kernel-image + kernel-devicetree for RPi already come from
# include/raspberrypi.yml; the base IMAGE_INSTALL adds kernel-modules for every
# machine. No RPi-specific kernel install is needed here.
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
    # Python so we don't have to worry about shell quoting at all — we
    # just write the file directly. Also handles idempotent rewrite of
    # /etc/os-release on incremental rebuilds (no appended duplicates).
    import os
    import re

    rootfs = d.getVar('IMAGE_ROOTFS')
    tag = d.getVar('OE5XRX_RELEASE_TAG') or 'dev'

    # Reject anything that isn't a plain release tag. Our tags come from
    # `git tag vX.Y.Z` pushed into github.ref_name — disciplined input.
    # Blocking everything outside this charset means downstream code
    # (os-release parsers, shells that source it, /etc/issue, the
    # station-agent's heartbeat) never has to reason about escaping:
    # no quotes, no backslashes, no $, no backticks, no newlines.
    if not re.fullmatch(r'[A-Za-z0-9._-]+', tag):
        bb.fatal(
            f"OE5XRX_RELEASE_TAG={tag!r} contains characters outside "
            "[A-Za-z0-9._-]; pick a cleaner git tag."
        )

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

# x86 ESP fstab: mount /boot by PARTLABEL=efi, not the FAT UUID. wic's
# bootimg-efi (--use-uuid) would bake the build-time FAT UUID into fstab, but
# OTA rewrites only the rootfs — so an OTA'd slot's UUID never matches the
# on-disk ESP (from the originally-flashed image) and /boot times out at boot
# → systemd emergency mode → rollback. The x64 wks sets --no-fstab-update; we
# add a stable PARTLABEL=efi entry here. nofail: a bad/absent ESP must never
# brick boot — GRUB reads grubenv from the ESP directly, the Linux mount only
# exists so the station-agent can grub-editenv on OTA commit. Idempotent:
# replaces any stray /boot line, else appends.
python add_efi_fstab() {
    import os
    fstab = os.path.join(d.getVar('IMAGE_ROOTFS'), 'etc/fstab')
    entry = 'PARTLABEL=efi\t/boot\tvfat\tdefaults,nofail\t0\t0\n'
    lines = []
    if os.path.exists(fstab):
        with open(fstab) as f:
            lines = f.readlines()
    for i, line in enumerate(lines):
        fields = line.split()
        if len(fields) >= 2 and fields[1] == '/boot':
            bb.note('add_efi_fstab: replacing existing /boot entry: %r' % line.strip())
            lines[i] = entry
            break
    else:
        # guard against a base fstab whose last line lacks a trailing newline
        if lines and not lines[-1].endswith('\n'):
            lines[-1] += '\n'
        lines.append(entry)
    with open(fstab, 'w') as f:
        f.writelines(lines)
    bb.note('add_efi_fstab: ensured PARTLABEL=efi /boot entry')
}
ROOTFS_POSTPROCESS_COMMAND:append:qemux86-64 = " add_efi_fstab;"

# L0b — authoritative guard against the #37 bug class: fail the build if the
# baked /etc/fstab mounts any filesystem by a build-unstable device UUID.
# OTA rewrites only the rootfs, so a UUID= (or /dev/disk/by-uuid/) mount never
# matches the on-disk device after a cross-build OTA → boot hang / emergency
# mode → rollback. Only PARTLABEL / LABEL / kernel-cmdline root are OTA-safe.
# The fast static counterpart is scripts/l0a-fstab-uuid-lint.sh (every PR).
python assert_no_uuid_fstab() {
    import os
    fstab = os.path.join(d.getVar('IMAGE_ROOTFS'), 'etc/fstab')
    if not os.path.exists(fstab):
        return
    with open(fstab) as f:
        for lineno, line in enumerate(f, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            device = stripped.split()[0]
            if device.startswith('UUID=') or device.startswith('/dev/disk/by-uuid/'):
                bb.fatal(
                    'assert_no_uuid_fstab: /etc/fstab line %d mounts by device UUID '
                    '(%r) — not OTA-safe. Use PARTLABEL=. See #37.' % (lineno, stripped)
                )
}
ROOTFS_POSTPROCESS_COMMAND += "assert_no_uuid_fstab;"
