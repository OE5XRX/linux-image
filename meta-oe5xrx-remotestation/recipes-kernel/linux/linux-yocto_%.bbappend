FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://oe5xrx-watchdog.cfg"

# NOTE: the kernel version pin lives in oe5xrx.yml's local_conf_header
# (PREFERRED_VERSION_linux-yocto / _linux-raspberrypi) — PREFERRED_VERSION is
# conf-level provider metadata, not per-recipe, and the RPi kernel provider is
# linux-raspberrypi (not linux-yocto), so pinning must cover both there.
