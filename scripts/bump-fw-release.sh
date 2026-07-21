#!/usr/bin/env bash
#
# Single-source FW-RemoteStation release pinning for this Yocto layer.
#
# The release tag lives in exactly ONE place —
#   meta-oe5xrx-remotestation/conf/oe5xrx-fw-release.inc  (FW_RELEASE_TAG)
# — and every consuming recipe interpolates it into SRC_URI. One image = one FW
# release across the real DFU firmware, the native_sim ELF and the SA818 emulator.
# The only per-asset value is the sha256 (BitBake's fetch-time integrity gate).
# This script rewrites the tag + all three sha256s, cosign-verifying each asset
# (authenticity) and cross-checking its sha against the release SHA256SUMS.
#
# Usage:
#   scripts/bump-fw-release.sh <tag>     # re-pin the whole layer to <tag>
#   scripts/bump-fw-release.sh --check   # verify current pins, no rewrite (CI gate)
#
# Requires: cosign, curl, sha256sum on PATH.
set -euo pipefail

readonly COSIGN_IDENTITY_RE='^https://github.com/OE5XRX/FW-RemoteStation/\.github/workflows/release\.yml@refs/heads/main$'
readonly COSIGN_ISSUER='https://token.actions.githubusercontent.com'

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
inc="${repo_root}/meta-oe5xrx-remotestation/conf/oe5xrx-fw-release.inc"
recipes_dir="${repo_root}/meta-oe5xrx-remotestation/recipes-core"

# asset : recipe : sha-key  — every asset is driven by the single FW_RELEASE_TAG.
# sha-key is the SRC_URI[...] checksum flavour in that recipe.
readonly ASSETS="fm-sa818-2m.native_sim:${recipes_dir}/oe5xrx-native-sim-fm/oe5xrx-native-sim-fm.bb:sha256sum
fm-sa818-2m.sa818-sim.py:${recipes_dir}/oe5xrx-sim-harness/oe5xrx-sim-harness_1.0.bb:sa818sim.sha256sum
fm-sa818-2m.bin:${recipes_dir}/oe5xrx-fm-firmware/oe5xrx-fm-firmware.bb:sha256sum"

fail() { echo "bump-fw-release: $*" >&2; exit 1; }

for tool in cosign curl sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool not on PATH"
done
[ -f "$inc" ] || fail "include not found: $inc"

# One temp root under this dir, cleaned on EVERY exit path — including fail()->exit —
# so a mid-run download/cosign failure never leaks a temp dir. All mktemps below live
# under it (full-path templates: portable across GNU and BSD userlands).
_tmproot="$(mktemp -d "${TMPDIR:-/tmp}/bump-fw.XXXXXX")"
trap 'rm -rf "$_tmproot"' EXIT

url_base() {
    sed -nE 's/^FW_RELEASE_URL_BASE[[:space:]]*\?=[[:space:]]*"([^"]+)".*/\1/p' "$inc"
}

inc_tag() {
    sed -nE 's/^FW_RELEASE_TAG[[:space:]]*\?=[[:space:]]*"([^"]+)".*/\1/p' "$inc"
}

set_inc_tag() {
    grep -qE '^FW_RELEASE_TAG[[:space:]]*\?=' "$inc" || fail "FW_RELEASE_TAG not in $inc"
    _t="$(mktemp "${_tmproot}/tag.XXXXXX")"
    awk -v val="$1" '
        /^FW_RELEASE_TAG[[:space:]]*\?=/ { print "FW_RELEASE_TAG ?= \"" val "\""; next }
        { print }
    ' "$inc" > "$_t"
    cat "$_t" > "$inc"; rm -f "$_t"
}

recipe_sha() {
    _recipe="$1"; _esc="$(printf '%s' "$2" | sed 's/\./\\./g')"
    # Tolerant of hex case; normalize to lowercase so --check never false-negatives
    # on an uppercase or reformatted sha.
    sed -nE "s/^SRC_URI\\[${_esc}\\][[:space:]]*=[[:space:]]*\"([0-9a-fA-F]+)\".*/\\1/p" "$_recipe" | tr 'A-F' 'a-f'
}

set_recipe_sha() {
    _recipe="$1"; _key="$2"; _sha="$3"
    _esc="$(printf '%s' "$_key" | sed 's/\./\\./g')"
    grep -qE "^SRC_URI\\[${_esc}\\][[:space:]]*=" "$_recipe" \
        || fail "SRC_URI[$_key] not in $_recipe"
    _t="$(mktemp "${_tmproot}/sha.XXXXXX")"
    awk -v key="$_key" -v sha="$_sha" '
        index($0, "SRC_URI[" key "]") == 1 { print "SRC_URI[" key "] = \"" sha "\""; next }
        { print }
    ' "$_recipe" > "$_t"
    cat "$_t" > "$_recipe"; rm -f "$_t"
}

# Download <asset> for <tag>, cosign-verify, cross-check sha vs SHA256SUMS; echo the sha.
verify_asset() {
    _tag="$1"; _asset="$2"
    _base="$(url_base)/${_tag}"
    _tmp="$(mktemp -d "${_tmproot}/asset.XXXXXX")"
    curl -fsSL "${_base}/${_asset}"        -o "${_tmp}/${_asset}"        || fail "download failed: ${_base}/${_asset}"
    curl -fsSL "${_base}/${_asset}.bundle" -o "${_tmp}/${_asset}.bundle" || fail "download failed: ${_base}/${_asset}.bundle"
    curl -fsSL "${_base}/SHA256SUMS"       -o "${_tmp}/SHA256SUMS"       || fail "download failed: ${_base}/SHA256SUMS"
    cosign verify-blob \
        --certificate-identity-regexp "$COSIGN_IDENTITY_RE" \
        --certificate-oidc-issuer "$COSIGN_ISSUER" \
        --bundle "${_tmp}/${_asset}.bundle" \
        "${_tmp}/${_asset}" >/dev/null 2>&1 \
        || fail "cosign verification FAILED for ${_asset}@${_tag}"
    _sha="$(sha256sum "${_tmp}/${_asset}" | cut -d' ' -f1)"
    _exp="$(awk -v f="$_asset" '$2==f {print $1}' "${_tmp}/SHA256SUMS")"
    [ -n "$_exp" ] || fail "${_asset} not listed in SHA256SUMS@${_tag}"
    [ "$_sha" = "$_exp" ] || fail "sha256 mismatch for ${_asset}@${_tag}: computed $_sha, SHA256SUMS $_exp"
    rm -rf "$_tmp"
    printf '%s' "$_sha"
}

bump() {
    _tag="$1"
    echo "Re-pinning FW_RELEASE_TAG -> ${_tag}" >&2
    # Phase 1: verify EVERY asset and collect its sha BEFORE writing anything.
    # A here-doc (not a pipe) keeps the loop in the current shell, so verify_asset's
    # fail()->exit aborts the whole run — and since no recipe has been touched yet,
    # a mid-run download/cosign/sha failure leaves the worktree untouched (no partial
    # update where some recipes/tag are new and others old).
    _pins=""
    while IFS=: read -r asset recipe key; do
        [ -n "$asset" ] || continue
        echo "  verify ${asset}@${_tag} ..." >&2
        sha="$(verify_asset "$_tag" "$asset")"
        echo "  OK  ${asset}  sha256=${sha}  (cosign verified)" >&2
        _pins="${_pins}${recipe}:${key}:${sha}
"
    done <<EOF
${ASSETS}
EOF
    # Phase 2: all verified — commit the shas, then the tag. Here-doc again so a
    # set_recipe_sha failure (missing key) still aborts instead of dying in a subshell.
    while IFS=: read -r recipe key sha; do
        [ -n "$recipe" ] || continue
        set_recipe_sha "$recipe" "$key" "$sha"
        echo "  pinned $(basename "$recipe")  SRC_URI[$key]" >&2
    done <<EOF
${_pins}
EOF
    set_inc_tag "$_tag"
    echo "Pinned FW_RELEASE_TAG=${_tag}" >&2
}

check() {
    _tag="$(inc_tag)"
    [ -n "$_tag" ] || fail "FW_RELEASE_TAG unset in include"
    printf '%s\n' "$ASSETS" | while IFS=: read -r asset recipe key; do
        [ -n "$asset" ] || continue
        recorded="$(recipe_sha "$recipe" "$key")"
        [ -n "$recorded" ] || fail "no recorded sha for SRC_URI[$key] in $(basename "$recipe")"
        actual="$(verify_asset "$_tag" "$asset")"
        if [ "$recorded" = "$actual" ]; then
            echo "OK  ${asset}@${_tag}  sha matches, cosign verified" >&2
        else
            fail "${asset}@${_tag} sha drift: recipe=$recorded release=$actual"
        fi
    done
    echo "All FW-release pins verified (cosign + sha256) @ ${_tag}." >&2
}

case "${1:-}" in
    "" ) fail "usage: $0 <tag> | --check" ;;
    --check) check ;;
    --*) fail "usage: $0 <tag> | --check" ;;
    *) bump "$1" ;;
esac
