SUMMARY = "OE5XRX boot robustness: hung-task panic sysctl + watchdog glue"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
SRC_URI = "file://50-oe5xrx-panic.conf"
S = "${WORKDIR}"
inherit allarch
do_install() {
    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${WORKDIR}/50-oe5xrx-panic.conf ${D}${sysconfdir}/sysctl.d/
}
FILES:${PN} = "${sysconfdir}/sysctl.d/50-oe5xrx-panic.conf"
