# --- CM4 USB fix: pin the 6.18 kernel to rpi-6.18.y HEAD (6.18.39) ---
# meta-raspberrypi's wrynose pin is 6.18.33; that kernel times out the DTR
# SET_CONTROL_LINE_STATE control transfer to the FM module (composite UAC2+CDC
# FS device behind the FE1.1s single-TT hub). On-target config + DTB are
# byte-identical to Raspberry Pi OS, so pin source + defconfig to rpi-6.18.y
# HEAD (6.18.39, 60ea684) which carries endpoint/xhci fixes past our old pin
# (e.g. "Fix up Interrupt IN endpoints with bogus wBytesPerInterval" — the CDC
# notification IF has an interrupt-IN endpoint).
#
# Version-specific on purpose: a %-wide or a :pn- override hits ALL
# linux-raspberrypi versions (6.1/6.6/6.12) too and makes them advertise
# 6.18.39, so PREFERRED_VERSION=6.18.% picks e.g. the 6.1 recipe which then
# fetches its own KBRANCH (rpi-6.1.y) and can't find the commit. Scoped to
# _6.18 only. x86 (no linux-raspberrypi recipe) tolerates this dangling append
# via BB_DANGLINGAPPENDS_WARNONLY in oe5xrx.yml.
LINUX_VERSION = "6.18.39"
SRCREV_machine = "60ea684a8ace97bb0db1a16e20753bdd6ab371ff"
