SUMMARY = "OE5XRX A/B boot script + U-Boot env config"
DESCRIPTION = "Provides boot.scr (A/B selection logic) and fw_env.config \
so userspace can read/write the U-Boot environment with fw_setenv."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://boot.cmd \
    file://fw_env.config \
"

S = "${WORKDIR}"

inherit allarch

DEPENDS = "u-boot-tools-native"

# Skip on machines without U-Boot.
COMPATIBLE_MACHINE = "^(raspberrypi.*|.*cm4.*)$"

do_compile() {
    # mkimage wraps boot.cmd in a U-Boot legacy-image header so U-Boot
    # recognizes it as a script.
    mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 \
        -n "OE5XRX A/B boot" \
        -d ${WORKDIR}/boot.cmd ${WORKDIR}/boot.scr
}

do_install() {
    # boot.scr goes in the firmware FAT partition so U-Boot finds it.
    install -d ${D}/boot/firmware
    install -m 0644 ${WORKDIR}/boot.scr ${D}/boot/firmware/boot.scr
    install -m 0644 ${WORKDIR}/boot.cmd ${D}/boot/firmware/boot.cmd

    # fw_env.config in /etc for fw_printenv/fw_setenv.
    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}

FILES:${PN} = "/boot/firmware/boot.scr /boot/firmware/boot.cmd ${sysconfdir}/fw_env.config"

# FIXME(u-boot-env-partition): meta-raspberrypi's default U-Boot stores the env
# at a board-specific offset, not in /dev/disk/by-partlabel/uboot_env. To make
# fw_env.config above actually work, the U-Boot build needs a bbappend that
# sets CONFIG_ENV_IS_IN_MMC with CONFIG_ENV_OFFSET/_REDUND matching the wks
# partition offsets (or, cleaner, switch to CONFIG_ENV_IS_IN_FAT or similar).
# Until then the A/B boot script runs but the env is in the default location
# and fw_setenv will need the same offsets patched into fw_env.config.
