FILESEXTRAPATHS:prepend := "${THISDIR}/files:"
SRC_URI:append = " file://oe5xrx-watchdog.cfg"
# Audio sim substrate (Spec 0 §8): snd-aloop + base ALSA for the qemux86-64
# image. linux-yocto is x86-only here, so this never reaches the RPi kernel
# (which uses linux-raspberrypi and real UAC2 instead of the loopback).
SRC_URI:append = " file://oe5xrx-snd-aloop.cfg"

# NOTE: the kernel version pin lives in oe5xrx.yml's local_conf_header
# (PREFERRED_VERSION_linux-yocto / _linux-raspberrypi) — PREFERRED_VERSION is
# conf-level provider metadata, not per-recipe, and the RPi kernel provider is
# linux-raspberrypi (not linux-yocto), so pinning must cover both there.
