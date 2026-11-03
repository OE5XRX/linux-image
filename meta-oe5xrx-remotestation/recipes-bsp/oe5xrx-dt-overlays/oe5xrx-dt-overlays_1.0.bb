SUMMARY = "OE5XRX device-tree overlays for the CM4 (PowerBoard INA226)"
DESCRIPTION = "Compiles OE5XRX DT overlays and deploys them for the RPi \
firmware FAT partition. The GPU firmware applies them from config.txt."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://oe5xrx-ina226-overlay.dts"

S = "${UNPACKDIR}"

inherit deploy

DEPENDS = "dtc-native"
INHIBIT_DEFAULT_DEPS = "1"
# Board-specific DT content.
PACKAGE_ARCH = "${MACHINE_ARCH}"

# Only meaningful where the RPi firmware applies overlays from config.txt.
COMPATIBLE_MACHINE = "^(raspberrypi.*|.*cm4.*)$"

do_compile() {
    # -@ keeps the &i2c1 reference as a __fixups__ entry the firmware resolves
    # against the base DTB's __symbols__.
    dtc -@ -I dts -O dtb -o ${B}/oe5xrx-ina226.dtbo \
        ${UNPACKDIR}/oe5xrx-ina226-overlay.dts
}

do_install[noexec] = "1"

do_deploy() {
    # The image recipe routes it onto the FAT partition as
    # overlays/oe5xrx-ina226.dtbo via IMAGE_BOOT_FILES.
    install -m 0644 ${B}/oe5xrx-ina226.dtbo ${DEPLOYDIR}/oe5xrx-ina226.dtbo
}
addtask deploy after do_compile before do_build
