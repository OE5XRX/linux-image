SUMMARY = "OE5XRX FM transceiver firmware (SA818, 2m) — DFU payload"
DESCRIPTION = "Real FM module firmware (.bin) pinned from a FW-RemoteStation release, \
cosign-verified. This is the DFU source flashed onto a real FM module; bundled into the image for \
later DFU use."
LICENSE = "CLOSED"

# The release tag is the single source of truth in conf/oe5xrx-fw-release.inc
# (FW_RELEASE_TAG — the SAME tag as the sim assets: one image = one FW release across
# real firmware and sim). Re-pin the whole layer with:
#   scripts/bump-fw-release.sh <tag>  (rewrites the tag + all shas, cosign-verified).
require conf/oe5xrx-fw-release.inc
SRC_URI = "${FW_RELEASE_URL_BASE}/${FW_RELEASE_TAG}/fm-sa818-2m.bin"
SRC_URI[sha256sum] = "3fecc86119d36ea8f0853013b7488682fe0bb99fc314ab3620489973b7aaaafc"

# PV = the dotted date part of the tag (e.g. 26.07.21-01 -> 26.07.21).
PV = "${@d.getVar('FW_RELEASE_TAG').split('-')[0]}"

S = "${WORKDIR}"

inherit allarch

do_install() {
    install -d ${D}${nonarch_base_libdir}/firmware/oe5xrx
    install -m 0644 ${WORKDIR}/fm-sa818-2m.bin ${D}${nonarch_base_libdir}/firmware/oe5xrx/fm-sa818-2m.bin
}

FILES:${PN} = "${nonarch_base_libdir}/firmware/oe5xrx/fm-sa818-2m.bin"
