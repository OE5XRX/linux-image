SUMMARY = "OE5XRX sim harness — native_sim FM behind slot1/control pty (qemux86-64)"
DESCRIPTION = "Sim populator of the D2 slot contract. Runs the pinned native_sim FM binary, \
symlinks its console pty at /dev/oe5xrx/slot1/control, and attaches exactly one SA818 AT-emulator \
to the radio-link pty (uart_1) so set-type commands are answered instead of driver_error'ing on an \
unanswered UART. Both children are owned by the harness (systemd) — no stray/duplicate emulator. \
The emulator is pinned from the co-versioned FW-RemoteStation release asset (not vendored). \
No socat: native_sim owns the ptys."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# The SA818 AT-emulator is NOT vendored — it is pinned from the co-versioned
# FW-RemoteStation release asset (fm-sa818-2m.sa818-sim.py), the same canonical,
# unit-tested source the native_sim binary is built from. It shares the layer-wide
# release tag (FW_RELEASE_TAG, single source of truth in the include below), so
# emulator and sim binary stay in lockstep. Only the sha256 is per-asset; re-pin the
# whole layer with: scripts/bump-fw-release.sh <tag>  (rewrites tag + all shas).
require conf/oe5xrx-fw-release.inc
SRC_URI = " \
    file://sim-harness.sh \
    file://oe5xrx-sim-harness.service \
    ${FW_RELEASE_URL_BASE}/${FW_RELEASE_TAG}/fm-sa818-2m.sa818-sim.py;name=sa818sim;downloadfilename=sa818-sim.py \
"
SRC_URI[sa818sim.sha256sum] = "cb35b4ef54e9f71ddcae8f912a9184172dac7a621c4d0ebb5c5e7a8f5229c085"

S = "${WORKDIR}"

inherit systemd

# native_sim binary + the python3 stdlib split-packages the SA818 emulator imports:
#   os, re, sys, select, signal, dataclasses, typing, argparse -> python3-core
#   termios, tty                                               -> python3-terminal
#   threading                                                  -> python3-threading
# (argparse lives in python3-core in current OE-core — there is NO python3-argparse
# package; RDEPENDing on it made oe5xrx-sim-harness unbuildable. python3-io is kept
# as a belt-and-suspenders provider for select on manifests that split it out.)
RDEPENDS:${PN} += "oe5xrx-native-sim-fm \
    python3-core \
    python3-io \
    python3-terminal \
    python3-threading \
"

SYSTEMD_SERVICE:${PN} = "oe5xrx-sim-harness.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${sbindir}
    install -m 0755 ${WORKDIR}/sim-harness.sh ${D}${sbindir}/sim-harness.sh

    install -d ${D}${libexecdir}/oe5xrx
    install -m 0755 ${WORKDIR}/sa818-sim.py ${D}${libexecdir}/oe5xrx/sa818-sim.py

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/oe5xrx-sim-harness.service ${D}${systemd_system_unitdir}/oe5xrx-sim-harness.service
}

FILES:${PN} = " \
    ${sbindir}/sim-harness.sh \
    ${libexecdir}/oe5xrx/sa818-sim.py \
    ${systemd_system_unitdir}/oe5xrx-sim-harness.service \
"
