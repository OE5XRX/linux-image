FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
# One :append so both fragments are always applied: ext4 (boot.cmd ext4load's
# the kernel from the rootfs) + watchdog (u-boot arms the SoC wdt).
SRC_URI:append:raspberrypi4-64 = " file://oe5xrx-ext4.cfg file://oe5xrx-wdt.cfg"
