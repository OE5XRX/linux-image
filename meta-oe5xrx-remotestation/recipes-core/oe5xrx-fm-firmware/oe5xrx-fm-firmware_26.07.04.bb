SUMMARY = "OE5XRX FM transceiver firmware (SA818, 2m) — DFU payload"
DESCRIPTION = "Real FM module firmware (.bin) pinned from FW-RemoteStation release 26.07.04-01, \
cosign-verified. This is the DFU source flashed onto a real FM module; bundled into the image for \
later DFU use. Pin/re-pin with scripts/pin-fw-artifact.sh."
LICENSE = "CLOSED"

# Pinned FW-RemoteStation release 26.07.04-01 (URL + sha256 from SHA256SUMS, cosign-verified).
# Re-pin with: scripts/pin-fw-artifact.sh <this-recipe> <url>
SRC_URI = "https://github.com/OE5XRX/FW-RemoteStation/releases/download/26.07.04-01/fm-sa818-2m.bin"
SRC_URI[sha256sum] = "f7263b6b99014c95cfeeff84601be5f6e17a3e0861fef29d208e5a42ed4d71f7"

PV = "26.07.04"

S = "${WORKDIR}"

inherit allarch

do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware/oe5xrx
    install -m 0644 ${WORKDIR}/fm-sa818-2m.bin ${D}${nonarch_base_libdir}/firmware/oe5xrx/fm-sa818-2m.bin
}

FILES:${PN} = "${nonarch_base_libdir}/firmware/oe5xrx/fm-sa818-2m.bin"
