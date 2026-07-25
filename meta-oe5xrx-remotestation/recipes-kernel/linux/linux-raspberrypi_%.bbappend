# RPi's kernel provider is linux-raspberrypi (not linux-yocto), so the watchdog
# config fragment must be applied here too — otherwise CONFIG_BCM2835_WDT is not
# guaranteed built in, /dev/watchdog may be absent, and the u-boot `wdt start`
# pre-arm in boot.cmd would have nothing feeding it (reset-loop risk).
# The shared fragment also carries CONFIG_I6300ESB_WDT (x86-only); on arm64 that
# symbol is simply unsatisfiable and dropped by the kconfig merge — harmless.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://oe5xrx-watchdog.cfg"

# --- CM4 USB fix: pin to Raspberry Pi OS's exact working kernel commit ---
# We already build the Raspberry Pi kernel port (raspberrypi/linux rpi-6.18.y +
# in-tree bcm2711_defconfig). meta-raspberrypi's wrynose pin is 6.18.33; the FM
# module (composite UAC2+CDC full-speed device behind the FE1.1s single-TT hub)
# enumerates + talks reliably under Raspberry Pi OS (6.18.34+rpt-rpi) over XHCI,
# but on 6.18.33 the XHCI split-transaction handling drops the DTR control
# transfer (usbmon: Co ... 21 22 0003 -> -2) or fails enumeration outright
# ("invalid context state for evaluate context command"). Source + defconfig are
# identical upstream, so pin BOTH to Raspbian's exact 6.18.34 level (last
# rpi-6.18.y commit before the 6.18.35 version bump) -> kernel code AND config
# are 1:1 with the known-good Raspberry Pi OS kernel, no mixed sources.
LINUX_VERSION = "6.18.34"
SRCREV_machine = "918450ad6010df6ecd2efde12a1409e011da22d6"

# Build the running config into the kernel (/proc/config.gz, built-in so no
# `modprobe configs` needed) to verify config parity with Raspberry Pi OS
# on-target and debug USB without a rebuild.
SRC_URI:append = " file://oe5xrx-ikconfig.cfg"
