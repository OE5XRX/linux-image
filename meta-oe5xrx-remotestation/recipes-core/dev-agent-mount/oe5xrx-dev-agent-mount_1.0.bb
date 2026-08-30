SUMMARY = "OE5XRX Fast-Dev-Loop: live-mount launcher + station-agent drop-in (DEV ONLY)"
DESCRIPTION = "Ships a launcher that runs the station-agent from a host sshfs \
mount when present, else the baked agent. Installed only into the dev image."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://station-agent-dev-launch \
    file://dev-override.conf \
"

S = "${UNPACKDIR}"

inherit allarch

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${UNPACKDIR}/station-agent-dev-launch ${D}${bindir}/station-agent-dev-launch

    install -d ${D}${sysconfdir}/systemd/system/station-agent.service.d
    install -m 0644 ${UNPACKDIR}/dev-override.conf \
        ${D}${sysconfdir}/systemd/system/station-agent.service.d/dev-override.conf

    # Bake the full sshfs mountpoint. The rootfs is read-only, so dev-mount.sh
    # cannot mkdir /mnt/dev/station_agent at runtime — it must already exist.
    install -d ${D}/mnt/dev/station_agent
}

FILES:${PN} += " \
    ${bindir}/station-agent-dev-launch \
    ${sysconfdir}/systemd/system/station-agent.service.d/dev-override.conf \
    /mnt/dev \
"
