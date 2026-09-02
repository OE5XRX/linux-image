#!/usr/bin/env bash
# CI: assert the image-variant marker wiring stays intact.
#  - prod image declares a weak-default OE5XRX_IMAGE_VARIANT
#  - dev image overrides it to "dev"
#  - stamp_release writes VARIANT_ID
set -euo pipefail
IMG_DIR="meta-oe5xrx-remotestation/recipes-core/images"
PROD="${IMG_DIR}/oe5xrx-remotestation-image.bb"
DEV="${IMG_DIR}/oe5xrx-remotestation-dev-image.bb"
fail=0

grep -Eq '^[[:space:]]*OE5XRX_IMAGE_VARIANT[[:space:]]*\?\?=[[:space:]]*"release"' "${PROD}" || {
  echo "::error file=${PROD}::prod image must weak-default OE5XRX_IMAGE_VARIANT to \"release\""; fail=1; }

grep -Eq '^[[:space:]]*OE5XRX_IMAGE_VARIANT[[:space:]]*=[[:space:]]*"dev"' "${DEV}" || {
  echo "::error file=${DEV}::dev image must set OE5XRX_IMAGE_VARIANT = \"dev\""; fail=1; }

grep -q "'VARIANT_ID': variant" "${PROD}" || {
  echo "::error file=${PROD}::stamp_release must write VARIANT_ID"; fail=1; }

exit "${fail}"
