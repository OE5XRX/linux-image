SUMMARY = "Dire Wolf: software soundcard TNC / APRS decoder"
DESCRIPTION = "Used RX-only by the passive APRS service (oe5xrx-decoder@aprs-slotN): \
audio on stdin, decoded packets only on a KISS TCP port. Separate program (GPL-2.0), \
not linked into the station agent."
HOMEPAGE = "https://github.com/wb2osz/direwolf"
LICENSE = "GPL-2.0-only"
LIC_FILES_CHKSUM = "file://LICENSE;md5=fa22e16ebbe6638b2bd253338fbded9f"

# Tag 1.8.1 (newest stable, 2025-11-13), pinned by commit. Never AUTOREV.
SRC_URI = "git://github.com/wb2osz/direwolf.git;protocol=https;branch=master;tag=${PV}"
SRCREV = "a231971a652bfb574a4bae9a5d875fbce53d2267"

inherit cmake pkgconfig

# ALSA only. Upstream probes gpsd/hamlib/gpiod/udev(CM108)/avahi with find_package;
# none of them are in DEPENDS, so none is found in the recipe sysroot and the
# image does not grow. DNS-SD is switched off explicitly as well.
DEPENDS = "alsa-lib"

EXTRA_OECMAKE = "-DOPTIONAL_DNSSD=OFF -DUNITTEST=OFF"

# Strip everything the RX-only decoder does not need: udev rule (CM108 PTT),
# desktop/menu files, shipped docs and sample data.
do_install:append() {
    rm -rf ${D}${sysconfdir}/udev ${D}${nonarch_libdir}/udev
    rmdir --ignore-fail-on-non-empty ${D}${nonarch_libdir}
    rm -rf ${D}${datadir}/applications
    rm -rf ${D}${datadir}/pixmaps
    rm -rf ${D}${datadir}/doc/direwolf
    rm -rf ${D}${datadir}/direwolf
}

# Only the decoder itself goes into the image; decode_aprs, kissutil, ... are
# split into ${PN}-tools, which is not installed.
PACKAGES += "${PN}-tools"
FILES:${PN} = "${bindir}/direwolf"
FILES:${PN}-tools = "${bindir}/*"
