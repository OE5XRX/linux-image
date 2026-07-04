SUMMARY = "OE5XRX sim harness — native_sim FM behind slot1/control pty (dev-only)"
DESCRIPTION = "Sim populator of the D2 slot contract. Runs the pinned native_sim FM binary and \
symlinks its console pty at /dev/oe5xrx/slot1/control. No socat: native_sim owns the pty."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://sim-harness.sh \
    file://oe5xrx-sim-harness.service \
"

S = "${WORKDIR}"

inherit systemd

RDEPENDS:${PN} += "oe5xrx-native-sim-fm"

SYSTEMD_SERVICE:${PN} = "oe5xrx-sim-harness.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/sim-harness.sh ${D}${sbindir}/sim-harness.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/oe5xrx-sim-harness.service ${D}${systemd_system_unitdir}/oe5xrx-sim-harness.service
}

FILES:${PN} = " \
    ${sbindir}/sim-harness.sh \
    ${systemd_system_unitdir}/oe5xrx-sim-harness.service \
"
