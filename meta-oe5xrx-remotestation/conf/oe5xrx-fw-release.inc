# Single source of truth for the FW-RemoteStation release this layer pins.
#
# ONE tag for the whole layer: the real DFU firmware (<FW_FM_ASSET>.bin), the
# native_sim ELF and the SA818 emulator all come from the SAME FW release, so an
# image is always "FW release <tag>", period — sim and real firmware never drift
# apart within an image version.
#
# Consumed via `require conf/oe5xrx-fw-release.inc` (this dir is on BBPATH through
# `BBPATH .= ":${LAYERDIR}"` in conf/layer.conf). Each consuming recipe builds its
# SRC_URI from ${FW_RELEASE_URL_BASE}/${FW_RELEASE_TAG}/<asset> and derives PV from
# the tag — so a release bump touches only the tag line below plus the per-asset
# sha256, both rewritten + cosign-verified by scripts/bump-fw-release.sh <tag>.
# No recipe rename, no URL edits, no gate/test path changes.
#
# FW_FM_ASSET is the release-asset basename of the (VHF/2m) FM build. FW-RemoteStation
# renamed it from `fm-sa818-2m` to `fm-sa818-vhf` (FW #66) — the first release cut
# after that ships `fm-sa818-vhf.*`. scripts/bump-fw-release.sh picks the name the
# target release actually carries (vhf preferred, 2m fallback) and rewrites this
# line together with the tag, so the rename is a pure bump — no recipe edit.

FW_RELEASE_URL_BASE ?= "https://github.com/OE5XRX/FW-RemoteStation/releases/download"
FW_RELEASE_TAG ?= "26.07.21-01"
FW_FM_ASSET ?= "fm-sa818-2m"
