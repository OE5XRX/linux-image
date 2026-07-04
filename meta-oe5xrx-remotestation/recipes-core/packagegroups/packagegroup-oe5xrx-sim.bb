SUMMARY = "OE5XRX co-located module simulation stack (dev-only)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit packagegroup

RDEPENDS:${PN} = " \
    oe5xrx-native-sim-fm \
    oe5xrx-sim-harness \
"
