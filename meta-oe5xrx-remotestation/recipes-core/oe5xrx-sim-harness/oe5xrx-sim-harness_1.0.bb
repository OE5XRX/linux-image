SUMMARY = "OE5XRX sim harness — native_sim FM behind slot1/control pty (qemux86-64)"
DESCRIPTION = "Sim populator of the D2 slot contract. Runs the pinned native_sim FM binary, \
symlinks its console pty at /dev/oe5xrx/slot1/control, and attaches exactly one SA818 AT-emulator \
to the radio-link pty (uart_1) so set-type commands are answered instead of driver_error'ing on an \
unanswered UART. Both children are owned by the harness (systemd) — no stray/duplicate emulator. \
No socat: native_sim owns the ptys."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://sim-harness.sh \
    file://sa818-sim.py \
    file://oe5xrx-sim-harness.service \
"

S = "${WORKDIR}"

inherit systemd

# native_sim binary + a python3 interpreter with the stdlib modules the SA818
# emulator uses (os/re/signal/dataclasses/typing are python3-core; the rest are
# their own OE-core module packages). These are already present in the image
# via station-agent, listed here explicitly so the sim-harness is self-contained.
RDEPENDS:${PN} += "oe5xrx-native-sim-fm \
    python3-core \
    python3-io \
    python3-terminal \
    python3-threading \
    python3-argparse \
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
