#!/usr/bin/env bash
#
# Pin a FW-RemoteStation release asset (URL + sha256) into a Yocto recipe.
#
# Fetches the asset, its cosign .bundle, and the release SHA256SUMS; verifies
# the cosign keyless signature (authenticity) and cross-checks the sha256
# (integrity) against SHA256SUMS; then rewrites the recipe's SRC_URI and
# SRC_URI[sha256sum]. The recipe's sha256sum is BitBake's fetch-time gate.
#
# Usage:
#   scripts/pin-fw-artifact.sh <recipe-path> <asset-download-url>
#   scripts/pin-fw-artifact.sh <recipe-path> <asset-download-url> --dry-run
#
# Requires: cosign, curl, sha256sum on PATH.
set -euo pipefail

RECIPE="${1:-}"
URL="${2:-}"
DRY_RUN=0
[ "${3:-}" = "--dry-run" ] && DRY_RUN=1

readonly COSIGN_IDENTITY_RE='^https://github.com/OE5XRX/FW-RemoteStation/\.github/workflows/release\.yml@refs/.+$'
readonly COSIGN_ISSUER='https://token.actions.githubusercontent.com'

fail() { echo "pin-fw-artifact: $*" >&2; exit 1; }

{ [ -n "$RECIPE" ] && [ -n "$URL" ]; } || fail "usage: $0 <recipe-path> <asset-url> [--dry-run]"
[ -f "$RECIPE" ] || fail "recipe not found: $RECIPE"
command -v cosign >/dev/null 2>&1 || fail "cosign not on PATH"

asset="$(basename "$URL")"
base_url="${URL%/*}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Fetching $asset, $asset.bundle, SHA256SUMS ..." >&2
curl -fsSL "$URL"                 -o "$tmp/$asset"
curl -fsSL "$URL.bundle"          -o "$tmp/$asset.bundle"
curl -fsSL "$base_url/SHA256SUMS" -o "$tmp/SHA256SUMS"

echo "Verifying cosign signature ..." >&2
cosign verify-blob \
    --certificate-identity-regexp "$COSIGN_IDENTITY_RE" \
    --certificate-oidc-issuer "$COSIGN_ISSUER" \
    --bundle "$tmp/$asset.bundle" \
    "$tmp/$asset" >/dev/null \
    || fail "cosign verification FAILED for $asset"

sha="$(sha256sum "$tmp/$asset" | cut -d' ' -f1)"
expected="$(awk -v f="$asset" '$2==f {print $1}' "$tmp/SHA256SUMS")"
[ -n "$expected" ] || fail "$asset not listed in SHA256SUMS"
[ "$sha" = "$expected" ] || fail "sha256 mismatch: computed $sha, SHA256SUMS $expected"

echo "OK  asset=$asset  sha256=$sha  (cosign verified)" >&2

if [ "$DRY_RUN" -eq 1 ]; then
    echo "(dry-run) $RECIPE not modified" >&2
    exit 0
fi

# Rewrite the two pinned lines. Recipe must already contain SRC_URI = "..." and
# SRC_URI[sha256sum] = "..." lines (placeholders are fine on first pin).
tmp_recipe="$(mktemp)"
awk -v url="$URL" -v sha="$sha" '
    /^SRC_URI\[sha256sum\][[:space:]]*=/ { print "SRC_URI[sha256sum] = \"" sha "\""; next }
    /^SRC_URI[[:space:]]*=/              { print "SRC_URI = \"" url "\""; next }
    { print }
' "$RECIPE" > "$tmp_recipe"
cat "$tmp_recipe" > "$RECIPE"   # preserve original mode
rm -f "$tmp_recipe"
echo "Pinned $RECIPE" >&2
