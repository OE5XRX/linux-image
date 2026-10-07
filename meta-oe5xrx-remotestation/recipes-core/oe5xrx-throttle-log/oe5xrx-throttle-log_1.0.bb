SUMMARY = "OE5XRX RPi throttle/undervoltage logger (oneshot + timer)"
DESCRIPTION = "Periodically logs `vcgencmd get_throttled` to the journal so \
undervoltage/throttle history survives a spontaneous reboot. RPi-only; the \
script self-guards (exit 0) when vcgencmd is absent."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://throttle-log.sh \
    file://oe5xrx-throttle-log.service \
    file://oe5xrx-throttle-log.timer \
"

S = "${UNPACKDIR}"

inherit systemd allarch

# vcgencmd lives in meta-raspberrypi's userland package.
RDEPENDS:${PN} += "userland"

SYSTEMD_SERVICE:${PN} = "oe5xrx-throttle-log.timer"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${UNPACKDIR}/throttle-log.sh ${D}${sbindir}/throttle-log.sh

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/oe5xrx-throttle-log.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${UNPACKDIR}/oe5xrx-throttle-log.timer   ${D}${systemd_system_unitdir}/
}

FILES:${PN} = " \
    ${sbindir}/throttle-log.sh \
    ${systemd_system_unitdir}/oe5xrx-throttle-log.service \
    ${systemd_system_unitdir}/oe5xrx-throttle-log.timer \
"
