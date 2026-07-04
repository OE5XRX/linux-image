SUMMARY = "OE5XRX co-located module simulation stack (dev-only)"
LICENSE = "MIT"

inherit packagegroup

RDEPENDS:${PN} = " \
    oe5xrx-native-sim-fm \
    oe5xrx-sim-harness \
"
