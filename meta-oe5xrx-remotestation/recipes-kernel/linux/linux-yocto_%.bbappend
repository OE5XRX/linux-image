FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://oe5xrx-watchdog.cfg"

# Pin the kernel so version/ext4-format drift is deliberate, not silent.
# Kernel-in-rootfs makes drift safe; this makes it intentional.
PREFERRED_VERSION_linux-yocto = "6.6.%"
