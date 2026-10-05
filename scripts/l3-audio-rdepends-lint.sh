#!/usr/bin/env bash
# Guard: the agent's GStreamer pipelines (RX/TX bridge + TX DSP chain) need specific
# split plugin packages at runtime. Missing one silently degrades the agent (e.g. no
# audiofx -> TX DSP falls back to pass-through), so pin them in oe5xrx-audio-system.
set -euo pipefail

RECIPE="${1:-meta-oe5xrx-remotestation/recipes-multimedia/oe5xrx-audio-system/oe5xrx-audio-system_1.0.bb}"
REQUIRED="gstreamer1.0-plugins-base-opus gstreamer1.0-pipewire gstreamer1.0-plugins-good-rtp
gstreamer1.0-plugins-good-udp gstreamer1.0-plugins-good-rtpmanager gstreamer1.0-plugins-good-audiofx"

# Only the RDEPENDS:${PN} block, comments stripped.
# shellcheck disable=SC2016  # literal ${PN} in the sed pattern
block=$(sed -n '/^RDEPENDS:\${PN}[[:space:]]*=/,/^"/p' "${RECIPE}" | grep -vE '^[[:space:]]*#')

fail=0
for pkg in ${REQUIRED}; do
    if ! grep -Eq "(^|[[:space:]\"])${pkg}([[:space:]\\\\\"]|$)" <<<"${block}"; then
        echo "::error file=${RECIPE}::RDEPENDS is missing '${pkg}'"
        fail=1
    fi
done
[ "${fail}" -eq 0 ] && echo "OK — audio RDEPENDS complete"
exit "${fail}"
