# --- CM4 USB fix: pin the 6.18 kernel to the latest rpi-6.18.y ---
# We build the Raspberry Pi kernel port (raspberrypi/linux rpi-6.18.y +
# in-tree bcm2711_defconfig). meta-raspberrypi's wrynose pin is 6.18.33
# (SRCREV 95b85be, dated 2026-05-27). Raspberry Pi OS runs 6.18.34+rpt-rpi and
# drives the FM module (composite UAC2 + CDC full-speed device behind the
# FE1.1s single-TT hub) reliably over XHCI, while 6.18.33 times out the DTR
# SET_CONTROL_LINE_STATE control transfer (usbmon: Co ... 21 22 0003 -> -2).
#
# On-target config + DTB are byte-identical to Raspberry Pi OS, but the kernel
# SOURCE isn't: between our 2026-05-27 pin and rpi-6.18.y HEAD there are
# endpoint/transfer fixes that plausibly hit this exact path, e.g.
#   - "usb: core: Fix up Interrupt IN endpoints with bogus wBytesPerInterval"
#     (the CDC notification IF has an interrupt-IN endpoint)
#   - "usb: xhci: Make usb_host_endpoint.hcpriv survive endpoint_disable()"
# Pin source + defconfig to the current rpi-6.18.y HEAD (6.18.39) so we get all
# of them, from one commit (no mixed sources). Requires a reflash.
#
# Must be version-specific (not linux-raspberrypi_%.bbappend) or it rewrites the
# 6.1/6.6/6.12 recipes and breaks PREFERRED_VERSION=6.18.% selection.
LINUX_VERSION = "6.18.39"
SRCREV_machine = "60ea684a8ace97bb0db1a16e20753bdd6ab371ff"
