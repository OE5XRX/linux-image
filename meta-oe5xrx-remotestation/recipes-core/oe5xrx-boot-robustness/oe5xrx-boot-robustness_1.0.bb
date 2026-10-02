SUMMARY = "OE5XRX boot robustness: hung-task panic sysctl + watchdog glue"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
SRC_URI = "file://50-oe5xrx-panic.conf \
           file://watchdog.conf \
           file://journald-persistent.conf \
           file://pstore.conf \
           file://sys-fs-pstore.mount \
"
S = "${UNPACKDIR}"
inherit allarch systemd
# Mount /sys/fs/pstore at boot — this systemd has no pstore PACKAGECONFIG so it
# would otherwise never be mounted and the crash records would be unreadable.
SYSTEMD_SERVICE:${PN} = "sys-fs-pstore.mount"
SYSTEMD_AUTO_ENABLE = "enable"
do_install() {
    install -d ${D}${sysconfdir}/sysctl.d
    install -m 0644 ${UNPACKDIR}/50-oe5xrx-panic.conf ${D}${sysconfdir}/sysctl.d/

    install -d ${D}${sysconfdir}/systemd/system.conf.d
    install -m 0644 ${UNPACKDIR}/watchdog.conf ${D}${sysconfdir}/systemd/system.conf.d/

    install -d ${D}${sysconfdir}/systemd/journald.conf.d
    install -m 0644 ${UNPACKDIR}/journald-persistent.conf ${D}${sysconfdir}/systemd/journald.conf.d/

    install -m 0644 ${UNPACKDIR}/pstore.conf ${D}${sysconfdir}/systemd/pstore.conf

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/sys-fs-pstore.mount ${D}${systemd_system_unitdir}/
}
FILES:${PN} = "${sysconfdir}/sysctl.d/50-oe5xrx-panic.conf \
               ${sysconfdir}/systemd/system.conf.d/watchdog.conf \
               ${sysconfdir}/systemd/journald.conf.d/journald-persistent.conf \
               ${sysconfdir}/systemd/pstore.conf \
               ${systemd_system_unitdir}/sys-fs-pstore.mount \
"
