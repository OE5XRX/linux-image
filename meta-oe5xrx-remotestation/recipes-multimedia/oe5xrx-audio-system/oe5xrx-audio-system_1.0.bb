SUMMARY = "OE5XRX system-wide audio stack (PipeWire + WirePlumber + GStreamer/Opus)"
DESCRIPTION = "Session-A audio image foundation (Spec 0 §3/§4/§7-A). Pulls PipeWire, \
WirePlumber, the GStreamer PipeWire + Opus elements and libopus into the image, and runs \
PipeWire/WirePlumber as SYSTEM services (headless appliance, not per-user) owned by the \
dedicated 'pipewire' user. Ships the WirePlumber rule that renames each module's ALSA card \
to the stable per-slot node 'oe5xrx.slotN'. Interface for Session B (station_agent): connect \
to the socket /run/pipewire/pipewire-0 as a member of group 'pipewire'."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = " \
    file://oe5xrx-pipewire.service \
    file://oe5xrx-wireplumber.service \
    file://10-oe5xrx-pipewire-system.conf \
    file://51-oe5xrx-slot-naming.conf \
"

S = "${UNPACKDIR}"

# allarch: this recipe ships only arch-independent content (config drop-ins +
# systemd unit files). RDEPENDS on arch-specific runtime packages does NOT force a
# machine-arch package — same proven pattern as ab-layout (RDEPENDS parted/
# e2fsprogs) and grub-ab (RDEPENDS grub-editenv) in this layer. Staying allarch
# avoids rebuilding identical content once per MACHINE.
inherit systemd allarch

# Runtime audio stack. The metas pull the ALSA SPA plugin (module -> PipeWire
# node) and the WirePlumber modules; the GStreamer packages carry the bridge
# elements Session B and the sim tone shim use. The agent's LIVE Opus bridge
# (station_agent/audio/opus_bridge.py, build_rx_argv/build_tx_argv) is an
# RTP-over-UDP loopback, so it needs the rtp payloaders, the udp transport AND
# the jitter buffer in addition to the Opus/PipeWire elements:
#   opusenc/opusdec          -> gstreamer1.0-plugins-base-opus (see the base bbappend)
#   pipewiresrc/pipewiresink -> gstreamer1.0-pipewire
#   rtpopuspay/rtpopusdepay  -> gstreamer1.0-plugins-good-rtp
#   udpsink/udpsrc           -> gstreamer1.0-plugins-good-udp
#   rtpjitterbuffer          -> gstreamer1.0-plugins-good-rtpmanager
#   audiotestsrc/alsasink/audioconvert/audioresample -> gstreamer1.0-plugins-base
# gst-inspect-1.0 / gst-launch-1.0 live in the gstreamer1.0 package.
#
# NOTE: depend on the SPECIFIC split plugin packages, NOT the bare
# 'gstreamer1.0-plugins-good' — that top package is EMPTY (FILES=""), it only
# *RRECOMMENDS* '-meta', which is best-effort and can be dropped in an image
# build. Same reason we pin 'gstreamer1.0-plugins-base-opus' rather than bare
# '-base'. Pinning the three sub-plugins keeps the headless appliance image
# lean (no v4l2/jpeg/png/... from the full -good set) while guaranteeing the
# bridge elements are actually installed.
RDEPENDS:${PN} = " \
    pipewire \
    pipewire-tools \
    pipewire-modules-meta \
    pipewire-spa-plugins-meta \
    wireplumber \
    wireplumber-modules-meta \
    wireplumber-scripts \
    gstreamer1.0 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-base-opus \
    gstreamer1.0-pipewire \
    gstreamer1.0-plugins-good-rtp \
    gstreamer1.0-plugins-good-udp \
    gstreamer1.0-plugins-good-rtpmanager \
    libopus \
    alsa-utils \
    dbus \
"

SYSTEMD_SERVICE:${PN} = "oe5xrx-pipewire.service oe5xrx-wireplumber.service"
SYSTEMD_AUTO_ENABLE = "enable"

do_install() {
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${UNPACKDIR}/oe5xrx-pipewire.service    ${D}${systemd_system_unitdir}/oe5xrx-pipewire.service
    install -m 0644 ${UNPACKDIR}/oe5xrx-wireplumber.service ${D}${systemd_system_unitdir}/oe5xrx-wireplumber.service

    install -d ${D}${sysconfdir}/pipewire/pipewire.conf.d
    install -m 0644 ${UNPACKDIR}/10-oe5xrx-pipewire-system.conf ${D}${sysconfdir}/pipewire/pipewire.conf.d/10-oe5xrx-system.conf

    install -d ${D}${sysconfdir}/wireplumber/wireplumber.conf.d
    install -m 0644 ${UNPACKDIR}/51-oe5xrx-slot-naming.conf ${D}${sysconfdir}/wireplumber/wireplumber.conf.d/51-oe5xrx-slot-naming.conf
}

FILES:${PN} = " \
    ${systemd_system_unitdir}/oe5xrx-pipewire.service \
    ${systemd_system_unitdir}/oe5xrx-wireplumber.service \
    ${sysconfdir}/pipewire/pipewire.conf.d/10-oe5xrx-system.conf \
    ${sysconfdir}/wireplumber/wireplumber.conf.d/51-oe5xrx-slot-naming.conf \
"
