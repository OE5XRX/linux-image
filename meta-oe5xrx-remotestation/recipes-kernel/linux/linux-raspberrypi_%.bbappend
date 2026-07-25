# RPi's kernel provider is linux-raspberrypi (not linux-yocto), so the watchdog
# config fragment must be applied here too — otherwise CONFIG_BCM2835_WDT is not
# guaranteed built in, /dev/watchdog may be absent, and the u-boot `wdt start`
# pre-arm in boot.cmd would have nothing feeding it (reset-loop risk).
# The shared fragment also carries CONFIG_I6300ESB_WDT (x86-only); on arm64 that
# symbol is simply unsatisfiable and dropped by the kconfig merge — harmless.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://oe5xrx-watchdog.cfg"

# Build the running config into the kernel (/proc/config.gz, built-in so no
# `modprobe configs` needed) to verify config parity with Raspberry Pi OS
# on-target and debug USB without a rebuild. Version-agnostic, so it lives in
# the %-bbappend. The kernel SRCREV/version pin (CM4 USB fix) is 6.18-specific
# and lives in linux-raspberrypi_6.18.bbappend — setting it here would clobber
# the 6.1/6.6/6.12 recipes too and break PREFERRED_VERSION selection.
SRC_URI:append = " file://oe5xrx-ikconfig.cfg"
