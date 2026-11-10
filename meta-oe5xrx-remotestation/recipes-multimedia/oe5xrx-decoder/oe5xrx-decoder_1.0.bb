SUMMARY = "OE5XRX passive-service decoder host (sandboxed systemd template + wrapper)"
DESCRIPTION = "Template unit oe5xrx-decoder@<decoder>-slot<N>.service, started and stopped \
by the station agent (never enabled at boot). The agent writes \
/run/oe5xrx/decoder/<instance>.env; the wrapper validates it and runs \
pw-record | direwolf (RX-only, KISS on 127.0.0.1). Runs as the unprivileged user \
'oe5xrx-decoder' in group 'pipewire'."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://oe5xrx-decoder@.service \
    file://oe5xrx-decoder-run \
"

S = "${UNPACKDIR}"

# allarch: unit + shell script only (same reasoning as oe5xrx-audio-system).
inherit systemd useradd allarch

# Group 'pipewire' is created by the pipewire recipe; USERADD_DEPENDS orders the
# useradd so '--groups pipewire' resolves in the final /etc/group.
USERADD_PACKAGES = "${PN}"
USERADD_DEPENDS = "pipewire"
USERADD_PARAM:${PN} = "--system --no-create-home --home-dir /nonexistent --shell /sbin/nologin --user-group --groups pipewire oe5xrx-decoder"

RDEPENDS:${PN} = "bash direwolf pipewire-tools"

# Template unit: instances are started by the agent, never enabled at boot.
SYSTEMD_SERVICE:${PN} = "oe5xrx-decoder@.service"
SYSTEMD_AUTO_ENABLE = "disable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/oe5xrx-decoder@.service ${D}${systemd_system_unitdir}/oe5xrx-decoder@.service

    install -d ${D}${libexecdir}/oe5xrx
    install -m 0755 ${UNPACKDIR}/oe5xrx-decoder-run ${D}${libexecdir}/oe5xrx/oe5xrx-decoder-run
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/oe5xrx-decoder@.service \
    ${libexecdir}/oe5xrx/oe5xrx-decoder-run \
"
