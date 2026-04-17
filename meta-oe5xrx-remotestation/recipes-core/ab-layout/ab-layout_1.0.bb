SUMMARY = "OE5XRX A/B layout: data partition mount + overlayfs-/etc glue"
DESCRIPTION = "Systemd mount units and first-boot initializer that wire up \
the persistent data partition (/mnt/data), bind /var, /home, /root onto it, \
and grow the partition to fill the device on first boot."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://mnt-data.mount \
    file://var.mount \
    file://home.mount \
    file://root.mount \
    file://etc-station-agent.mount \
    file://data-init.service \
    file://data-init.sh \
"

S = "${WORKDIR}"

inherit systemd allarch

SYSTEMD_SERVICE:${PN} = " \
    mnt-data.mount \
    var.mount \
    home.mount \
    root.mount \
    etc-station-agent.mount \
    data-init.service \
"
# boot-firmware.mount is NOT listed here — we install it to /etc/ and wire the
# wants symlink manually, because SYSTEMD_SERVICE drives systemctl enable
# which writes symlinks under /usr/lib; we need /etc/ to beat the fstab
# generator.
SYSTEMD_AUTO_ENABLE = "enable"

# parted + resize2fs for the first-boot partition/filesystem grow.
RDEPENDS:${PN} += "parted e2fsprogs-resize2fs util-linux-findmnt util-linux-lsblk"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/mnt-data.mount      ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/var.mount           ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/home.mount          ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/root.mount          ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/etc-station-agent.mount ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/data-init.service   ${D}${systemd_system_unitdir}/

    install -d ${D}${sysconfdir}/systemd/system
    install -d ${D}${sysconfdir}/systemd/system/local-fs.target.wants

    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/data-init.sh        ${D}${sbindir}/data-init.sh

    # The bind-mount targets must exist in the rootfs.
    install -d ${D}/mnt/data

    # Enable serial-getty on BOTH ttyAMA0 and ttyAMA1 — on real CM4 the
    # PL011 UART is ttyAMA0, but QEMU raspi4b registers it as ttyAMA1
    # (ttyAMA0 seems to be shadowed by another UART node). The one that
    # doesn't have a matching /dev/ entry simply gets skipped at runtime.
    install -d ${D}${sysconfdir}/systemd/system/getty.target.wants
    ln -sf /lib/systemd/system/serial-getty@.service \
        ${D}${sysconfdir}/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service
    ln -sf /lib/systemd/system/serial-getty@.service \
        ${D}${sysconfdir}/systemd/system/getty.target.wants/serial-getty@ttyAMA1.service
}

FILES:${PN} += "\
    /mnt/data \
    ${sysconfdir}/systemd/system/getty.target.wants/serial-getty@ttyAMA0.service \
    ${sysconfdir}/systemd/system/getty.target.wants/serial-getty@ttyAMA1.service \
"
