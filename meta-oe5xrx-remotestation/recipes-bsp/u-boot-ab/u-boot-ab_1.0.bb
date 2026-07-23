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

inherit allarch deploy

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

do_deploy() {
    # Stage the A/B boot script for wic. Named oe5xrx-boot.scr (not boot.scr)
    # to avoid a DEPLOY_DIR_IMAGE filename clash with meta-raspberrypi's
    # rpi-u-boot-scr. The image recipe installs it onto the FAT partition as
    # boot.scr via IMAGE_BOOT_FILES. Mirrors grub-ab's grubenv deploy.
    install -m 0644 ${WORKDIR}/boot.scr ${DEPLOYDIR}/oe5xrx-boot.scr
}
addtask deploy after do_compile before do_build

FILES:${PN} = "/boot/firmware/boot.scr /boot/firmware/boot.cmd ${sysconfdir}/fw_env.config"

# U-Boot stores its environment as redundant raw copies in the uboot_env /
# uboot_envr partitions, activated by recipes-bsp/u-boot/files/oe5xrx-env.cfg
# (CONFIG_ENV_IS_IN_MMC + redundant). The offsets there match this
# fw_env.config, so fw_printenv/fw_setenv and U-Boot share one env.
