SUMMARY = "OE5XRX Station Agent"
DESCRIPTION = "Remote station management agent with OTA updates, heartbeat, and terminal access"
LICENSE = "AGPL-3.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/AGPL-3.0-only;md5=73f1eb20517c55bf9493b7dd6e480788"

SRC_URI = " \
    git://github.com/OE5XRX/station-manager.git;protocol=https;branch=main;subpath=station_agent \
    file://station-agent.service \
    file://config.yml \
"
# Lockfile-style pin: SRCREV is always a specific commit, never ${AUTOREV}.
# Bump via scripts/pin-station-agent.sh, commit like any dependency update.
# The release workflow's preflight job refuses to build with AUTOREV.
SRCREV = "138fbac2c005f20cb819cad0cb18067627f7fc2c"
PV = "0.1.0+git${SRCPV}"

S = "${WORKDIR}/station_agent"

inherit python_setuptools_build_meta systemd

RDEPENDS:${PN} += " \
    python3-requests \
    python3-pyyaml \
    python3-cryptography \
    python3-websockets \
"

SYSTEMD_SERVICE:${PN} = "station-agent.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
    # systemd unit
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/station-agent.service ${D}${systemd_system_unitdir}/

    # Default config (operator-editable). Directory name is "stationagent"
    # without a dash so the etc-stationagent.mount unit doesn't need the
    # systemd \x2d path escape.
    install -d ${D}${sysconfdir}/stationagent
    install -m 0600 ${WORKDIR}/config.yml ${D}${sysconfdir}/stationagent/config.yml
}

CONFFILES:${PN} = "${sysconfdir}/stationagent/config.yml"
