SUMMARY = "OE5XRX Station Agent"
DESCRIPTION = "Remote station management agent with OTA updates, heartbeat, and terminal access"
LICENSE = "AGPL-3.0-only"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/AGPL-3.0-only;md5=73f1eb20517c55bf9493b7dd6e480788"

SRC_URI = " \
    git://github.com/OE5XRX/station-manager.git;protocol=https;branch=feat/audio-e2e-selftest-fix;subpath=station_agent \
    file://station-agent.service \
    file://config.yml \
"
# Lockfile-style pin: SRCREV is always a specific commit, never ${AUTOREV}.
# Bump via scripts/pin-station-agent.sh, commit like any dependency update.
# The release workflow's preflight job refuses to build with AUTOREV.
#
# TEMPORARY Session-E test-pin: this points at station-manager PR #124
# (feat/audio-e2e-selftest-fix), which repairs the `selftest audio` TX path that the
# Tier-1 QEMU E2E test (test_audio_agent_e2e.py) exercises. The branch override + this
# SRCREV are needed to build+prove the fix green in CI BEFORE #124 merges.
# >>> BEFORE MERGING THIS PR: revert branch= to main and re-pin SRCREV to the squashed
# >>> main commit of #124 via scripts/pin-station-agent.sh <sha>.
SRCREV = "f3920e3d89b0cc7461ca493a732bd35db769e621"
PV = "0.1.0+git${SRCPV}"

S = "${UNPACKDIR}/station_agent"

inherit python_setuptools_build_meta systemd

RDEPENDS:${PN} += " \
    python3-requests \
    python3-pyyaml \
    python3-cryptography \
    python3-websockets \
    python3-pyserial \
"

SYSTEMD_SERVICE:${PN} = "station-agent.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install:append() {
    # systemd unit
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/station-agent.service ${D}${systemd_system_unitdir}/

    # Default config (operator-editable). Directory name is "stationagent"
    # without a dash so the etc-stationagent.mount unit doesn't need the
    # systemd \x2d path escape.
    install -d ${D}${sysconfdir}/stationagent
    install -m 0600 ${UNPACKDIR}/config.yml ${D}${sysconfdir}/stationagent/config.yml
}

CONFFILES:${PN} = "${sysconfdir}/stationagent/config.yml"
