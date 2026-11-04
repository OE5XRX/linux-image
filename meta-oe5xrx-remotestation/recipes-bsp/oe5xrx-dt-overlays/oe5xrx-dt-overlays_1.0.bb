SUMMARY = "OE5XRX device-tree overlays for the CM4 (PowerBoard INA226)"
DESCRIPTION = "Compiles the OE5XRX DT overlays listed in OE5XRX_DT_OVERLAYS \
and installs them into the A/B slot rootfs (/boot/overlays/), where U-Boot \
boot stage 2 applies them to a copy of the firmware DTB."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# One files/<name>-overlay.dts per overlay name. The test overlays are only
# compiled/installed when OE5XRX_BOOT_TEST adds them to the list (dev builds).
SRC_URI = " \
    file://oe5xrx-ina226-overlay.dts \
    file://oe5xrx-test-marker-overlay.dts \
    file://oe5xrx-test-broken-overlay.dts \
"

# Overlay list (OE5XRX_DT_OVERLAYS_EFFECTIVE) shared with u-boot-ab, which bakes
# the same list into /boot/boot-stage2.scr.
require conf/oe5xrx-boot.inc

S = "${UNPACKDIR}"

DEPENDS = "dtc-native"
INHIBIT_DEFAULT_DEPS = "1"
# Board-specific DT content.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Only meaningful where U-Boot stage 2 applies overlays (CM4).
COMPATIBLE_MACHINE = "^(raspberrypi.*|.*cm4.*)$"

do_compile() {
    # -@ keeps label references (e.g. &i2c1) as __fixups__ entries that
    # `fdt apply` resolves against the firmware DTB's __symbols__.
    for n in ${OE5XRX_DT_OVERLAYS_EFFECTIVE}; do
        if [ ! -f ${UNPACKDIR}/$n-overlay.dts ]; then
            bbfatal "OE5XRX_DT_OVERLAYS lists '$n' but files/$n-overlay.dts is missing (add it to SRC_URI)."
        fi
        dtc -@ -I dts -O dtb -o ${B}/$n.dtbo ${UNPACKDIR}/$n-overlay.dts
    done
}
do_compile[vardeps] += "OE5XRX_DT_OVERLAYS_EFFECTIVE"

do_install() {
    # Into the slot's rootfs: travels with OTA and rolls back with the slot.
    # Stage 2 ext4load's /boot/overlays/<name>.dtbo from root_<slot>.
    install -d ${D}/boot/overlays
    for n in ${OE5XRX_DT_OVERLAYS_EFFECTIVE}; do
        install -m 0644 ${B}/$n.dtbo ${D}/boot/overlays/$n.dtbo
    done
}

FILES:${PN} = "/boot/overlays"
# An empty OE5XRX_DT_OVERLAYS must still yield an installable package.
ALLOW_EMPTY:${PN} = "1"
