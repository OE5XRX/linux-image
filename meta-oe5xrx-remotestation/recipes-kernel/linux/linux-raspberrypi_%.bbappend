# RPi's kernel provider is linux-raspberrypi (not linux-yocto), so the watchdog
# config fragment must be applied here too — otherwise CONFIG_BCM2835_WDT is not
# guaranteed built in, /dev/watchdog may be absent, and the u-boot `wdt start`
# pre-arm in boot.cmd would have nothing feeding it (reset-loop risk).
# The shared fragment also carries CONFIG_I6300ESB_WDT (x86-only); on arm64 that
# symbol is simply unsatisfiable and dropped by the kconfig merge — harmless.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://oe5xrx-watchdog.cfg"
