# --- CM4 USB fix: pin the 6.18 kernel to Raspberry Pi OS's exact working commit ---
# We already build the Raspberry Pi kernel port (raspberrypi/linux rpi-6.18.y +
# in-tree bcm2711_defconfig). meta-raspberrypi's wrynose pin is 6.18.33; the FM
# module (composite UAC2+CDC full-speed device behind the FE1.1s single-TT hub)
# enumerates + talks reliably under Raspberry Pi OS (6.18.34+rpt-rpi) over XHCI,
# but on 6.18.33 the XHCI split-transaction handling drops the DTR control
# transfer (usbmon: Co ... 21 22 0003 -> -2) or fails enumeration outright
# ("invalid context state for evaluate context command"). Source + defconfig are
# identical upstream, and the on-target config diff vs Raspberry Pi OS shows NO
# USB/XHCI/DMA/timing option differs — so pin BOTH source + defconfig to
# Raspbian's exact 6.18.34 level (918450ad = last rpi-6.18.y commit before the
# 6.18.35 bump) to close the remaining (non-USB) gap 1:1, no mixed sources.
#
# MUST be version-specific (not linux-raspberrypi_%.bbappend): setting
# LINUX_VERSION/SRCREV_machine globally rewrites the 6.1/6.6/6.12 recipes too,
# which then advertise 6.18.34 and get picked by PREFERRED_VERSION=6.18.% while
# still fetching their own KBRANCH (e.g. rpi-6.1.y) -> do_fetch can't find the
# commit. Scoped here, only the real rpi-6.18.y recipe is bumped.
LINUX_VERSION = "6.18.34"
SRCREV_machine = "918450ad6010df6ecd2efde12a1409e011da22d6"
