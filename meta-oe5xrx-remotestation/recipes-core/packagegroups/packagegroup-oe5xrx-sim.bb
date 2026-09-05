SUMMARY = "OE5XRX co-located module simulation stack (qemux86-64/Proxmox)"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

inherit packagegroup

RDEPENDS:${PN} = " \
    oe5xrx-native-sim-fm \
    oe5xrx-sim-harness \
    coreutils \
"

# coreutils: the audio okay-gate self-check (pushed into the guest at test time)
# needs `timeout` and `base64`, which the BusyBox base image does not provide.
# This lands ONLY in the qemux86-64 sim image (this packagegroup is qemux86-64
# only); the real rpi64 appliance image stays BusyBox-lean.
