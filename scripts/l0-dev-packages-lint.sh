#!/usr/bin/env bash
# Prod-Safety: Dev-only Pakete dürfen NIE im Prod-Image landen. Das Dev-Image
# require't das Prod-Image (Einbahn), also darf das Prod-Recipe die Dev-Pakete
# nicht referenzieren. Schützt CM4 UND die QEMU-Prod-Sim-Station auf Proxmox.
set -euo pipefail

PROD="meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb"
DEV="meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-dev-image.bb"
DEV_PKGS="sshfs-fuse fuse3 oe5xrx-dev-agent-mount"

fail=0
for pkg in ${DEV_PKGS}; do
    if grep -Eq "(^|[[:space:]]|\")${pkg}([[:space:]]|\\\\|\"|$)" <(grep -vE '^[[:space:]]*#' "${PROD}"); then
        echo "::error file=${PROD}::dev-only package '${pkg}' referenced in PROD image"
        fail=1
    fi
done

# Sicherstellen, dass das Dev-Image das Prod-Image require't (Einbahn-Invariante).
if ! grep -Eq '^[[:space:]]*require[[:space:]]+oe5xrx-remotestation-image\.bb' "${DEV}"; then
    echo "::error file=${DEV}::dev image must 'require oe5xrx-remotestation-image.bb'"
    fail=1
fi

[ "${fail}" -eq 0 ] && echo "OK — dev packages isolated from prod image"
exit "${fail}"
