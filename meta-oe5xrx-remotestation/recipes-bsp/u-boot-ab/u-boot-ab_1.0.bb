SUMMARY = "OE5XRX A/B boot script + U-Boot env config"
DESCRIPTION = "Provides boot stage 1 (boot.scr on the firmware FAT: env \
defaults, bootcount, watchdog, A/B rollback — frozen), boot stage 2 \
(/boot/boot-stage2.scr in the A/B slot rootfs: kernel, DT overlays, bootargs — \
updated by OTA) and fw_env.config so userspace can read/write the U-Boot \
environment with fw_setenv."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://boot.cmd \
    file://boot-stage2.cmd.in \
    file://boot-stage2-test-broken.cmd \
    file://fw_env.config \
"

# Overlay list + OE5XRX_BOOT_TEST fault switch (shared with oe5xrx-dt-overlays,
# so stage 2 and /boot/overlays/ always agree).
require conf/oe5xrx-boot.inc

S = "${UNPACKDIR}"

# allarch stays correct: the script text depends only on the global overlay
# list / test switch (not on MACHINE), and those are in the task signature via
# the vardeps below.
inherit allarch deploy

DEPENDS = "u-boot-tools-native"

# Skip on machines without U-Boot.
COMPATIBLE_MACHINE = "^(raspberrypi.*|.*cm4.*)$"

do_compile() {
    # mkimage wraps boot.cmd in a U-Boot legacy-image header so U-Boot
    # recognizes it as a script.
    mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 \
        -n "OE5XRX A/B boot" \
        -d ${UNPACKDIR}/boot.cmd ${UNPACKDIR}/boot.scr

    # Stage 2: fill the template placeholders. MUST stay byte-identical to
    # tests/ota-integration/boot_scripts.py render_stage2 (proven by
    # test_boot_recipes_static.py, which runs these exact sed expressions).
    # Values are [a-z0-9-] names plus " oe5xrx.overlays=ok:" — no sed
    # metacharacters (validated in conf/oe5xrx-boot.inc).
    if [ "${OE5XRX_BOOT_TEST}" = "stage2-broken" ]; then
        bbwarn "OE5XRX_BOOT_TEST=stage2-broken: shipping a deliberately broken boot stage 2 (dev test build)"
        cp ${UNPACKDIR}/boot-stage2-test-broken.cmd ${UNPACKDIR}/boot-stage2.cmd
    else
        sed -e 's|@OE5XRX_OVERLAYS_BOOTARG@|${OE5XRX_OVERLAYS_BOOTARG}|g' \
            -e 's|@OE5XRX_DT_OVERLAYS_CSV@|${OE5XRX_DT_OVERLAYS_CSV}|g' \
            -e 's|@OE5XRX_DT_OVERLAYS@|${OE5XRX_DT_OVERLAYS_EFFECTIVE}|g' \
            ${UNPACKDIR}/boot-stage2.cmd.in > ${UNPACKDIR}/boot-stage2.cmd
    fi
    if grep -q '@OE5XRX_' ${UNPACKDIR}/boot-stage2.cmd; then
        bbfatal "boot-stage2.cmd still contains an unrendered @OE5XRX_...@ placeholder — update the sed list in u-boot-ab (and boot_scripts.render_stage2)."
    fi
    mkimage -A arm64 -O linux -T script -C none -a 0 -e 0 \
        -n "OE5XRX boot stage 2" \
        -d ${UNPACKDIR}/boot-stage2.cmd ${UNPACKDIR}/boot-stage2.scr
}
# The rendered stage 2 depends on these (inc-derived at parse time).
do_compile[vardeps] += "OE5XRX_DT_OVERLAYS_EFFECTIVE OE5XRX_DT_OVERLAYS_CSV OE5XRX_OVERLAYS_BOOTARG OE5XRX_BOOT_TEST"

do_install() {
    # boot.scr goes in the firmware FAT partition so U-Boot finds it.
    install -d ${D}/boot/firmware
    install -m 0644 ${UNPACKDIR}/boot.scr ${D}/boot/firmware/boot.scr
    install -m 0644 ${UNPACKDIR}/boot.cmd ${D}/boot/firmware/boot.cmd

    # Stage 2 lives in the ROOTFS of the slot (updated by OTA, rolled back
    # with the slot); stage 1 ext4load's it from root_${boot_part}. The
    # rendered .cmd is shipped next to it for on-device inspection.
    install -d ${D}/boot
    install -m 0644 ${UNPACKDIR}/boot-stage2.scr ${D}/boot/boot-stage2.scr
    install -m 0644 ${UNPACKDIR}/boot-stage2.cmd ${D}/boot/boot-stage2.cmd

    # fw_env.config in /etc for fw_printenv/fw_setenv.
    install -d ${D}${sysconfdir}
    install -m 0644 ${UNPACKDIR}/fw_env.config ${D}${sysconfdir}/fw_env.config
}

do_deploy() {
    # Stage the A/B boot script for wic. Named oe5xrx-boot.scr (not boot.scr)
    # to avoid a DEPLOY_DIR_IMAGE filename clash with meta-raspberrypi's
    # rpi-u-boot-scr. The image recipe installs it onto the FAT partition as
    # boot.scr via IMAGE_BOOT_FILES. Mirrors grub-ab's grubenv deploy.
    install -m 0644 ${UNPACKDIR}/boot.scr ${DEPLOYDIR}/oe5xrx-boot.scr
}
addtask deploy after do_compile before do_build

FILES:${PN} = "/boot/firmware/boot.scr /boot/firmware/boot.cmd /boot/boot-stage2.scr /boot/boot-stage2.cmd ${sysconfdir}/fw_env.config"

# U-Boot stores its environment as redundant raw copies in the uboot_env /
# uboot_envr partitions, activated by recipes-bsp/u-boot/files/oe5xrx-env.cfg
# (CONFIG_ENV_IS_IN_MMC + redundant). The offsets there match this
# fw_env.config, so fw_printenv/fw_setenv and U-Boot share one env.
