SUMMARY = "OE5XRX slot contract udev rules (USB hub port -> /dev/oe5xrx/slotN/control)"
DESCRIPTION = "Real-HW half of the D2 slot contract. Maps fixed BusBoard hub ports to \
canonical slot control symlinks so the station_agent sees the same path in sim and real."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://90-oe5xrx-slots.rules"

S = "${WORKDIR}"

inherit allarch

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${WORKDIR}/90-oe5xrx-slots.rules ${D}${sysconfdir}/udev/rules.d/90-oe5xrx-slots.rules
}

FILES:${PN} = "${sysconfdir}/udev/rules.d/90-oe5xrx-slots.rules"
