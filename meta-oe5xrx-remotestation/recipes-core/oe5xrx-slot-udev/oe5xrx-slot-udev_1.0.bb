SUMMARY = "OE5XRX slot contract udev rules + slot->USB-port map (/etc/oe5xrx/slots.conf)"
DESCRIPTION = "Real-HW half of the D2 slot contract. Maps fixed BusBoard hub ports to \
canonical slot control symlinks so the station_agent sees the same path in sim and real, and \
ships the machine-readable slot->port map the agent uses for dfu-util -p <port>."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://90-oe5xrx-slots.rules file://slots.conf"

S = "${UNPACKDIR}"

inherit allarch

do_install() {
    install -d ${D}${sysconfdir}/udev/rules.d
    install -m 0644 ${UNPACKDIR}/90-oe5xrx-slots.rules ${D}${sysconfdir}/udev/rules.d/90-oe5xrx-slots.rules
    install -d ${D}${sysconfdir}/oe5xrx
    install -m 0644 ${UNPACKDIR}/slots.conf ${D}${sysconfdir}/oe5xrx/slots.conf
}

FILES:${PN} = " \
    ${sysconfdir}/udev/rules.d/90-oe5xrx-slots.rules \
    ${sysconfdir}/oe5xrx/slots.conf \
"
