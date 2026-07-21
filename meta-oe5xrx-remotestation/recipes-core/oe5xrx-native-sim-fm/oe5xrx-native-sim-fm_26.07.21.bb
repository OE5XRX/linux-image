SUMMARY = "Prebuilt Zephyr native_sim FM binary (qemux86-64 simulation)"
DESCRIPTION = "Statically-linked native_sim ELF pinned from FW-RemoteStation release 26.07.21-01, \
cosign-verified. Answers `module list` / `module <id> describe` on a self-created console pty. \
Consumed by oe5xrx-sim-harness. x86-only (COMPATIBLE_MACHINE = qemux86-64) so it ships only in the \
qemux86-64/Proxmox image, never on the RPi hardware image. Pin/re-pin with scripts/pin-fw-artifact.sh."
LICENSE = "CLOSED"

# Pinned FW-RemoteStation release 26.07.21-01 (URL + sha256 from SHA256SUMS, cosign-verified).
# Re-pin with: scripts/pin-fw-artifact.sh <this-recipe> <url>
SRC_URI = "https://github.com/OE5XRX/FW-RemoteStation/releases/download/26.07.21-01/fm-sa818-2m.native_sim;downloadfilename=fm-sa818-2m.native_sim"
SRC_URI[sha256sum] = "263f952c88d17ee9663819b743120acd272c3e87904151b3b4b167d47b55aae2"

PV = "26.07.21"

S = "${WORKDIR}"

COMPATIBLE_MACHINE = "qemux86-64"

# Prebuilt, statically-linked host-native x86-64 ELF (not cross-built by Yocto):
# bypass QA checks that assume cross-built, dynamically-linked artifacts.
INSANE_SKIP:${PN} = "already-stripped ldflags arch file-rdeps textrel staticdev"
EXCLUDE_FROM_SHLIBS = "1"

do_install() {
    install -d ${D}${libexecdir}/oe5xrx
    install -m 0755 ${WORKDIR}/fm-sa818-2m.native_sim ${D}${libexecdir}/oe5xrx/native-sim-fm
}

FILES:${PN} = "${libexecdir}/oe5xrx/native-sim-fm"
