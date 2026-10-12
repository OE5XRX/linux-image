#!/usr/bin/env bash
# Guard: SSH host keys must live on the persistent /var partition. With the
# read-only rootfs the upstream default is tmpfs (/var/run/ssh), which would
# regenerate the host key on every boot.
set -euo pipefail

BBAPPEND="${1:-meta-oe5xrx-remotestation/recipes-connectivity/openssh/openssh_%.bbappend}"
DROPIN="$(dirname "${BBAPPEND}")/files/sshdgenkeys-hostkey-dir.conf"

fail=0
if [ ! -f "${BBAPPEND}" ]; then
    echo "::error::missing ${BBAPPEND} (persistent SSH host keys)"
    exit 1
fi
if ! grep -Eq '^OPENSSH_HOST_KEY_DIR_READONLY_CONFIG[[:space:]]*=[[:space:]]*"\$\{localstatedir\}/lib/ssh"' "${BBAPPEND}"; then
    echo "::error file=${BBAPPEND}::OPENSSH_HOST_KEY_DIR_READONLY_CONFIG must be \${localstatedir}/lib/ssh"
    fail=1
fi
if ! grep -Eq '^PACKAGECONFIG:append[[:space:]]*=.*hostkey-ed25519' "${BBAPPEND}"; then
    echo "::error file=${BBAPPEND}::hostkey-ed25519 PACKAGECONFIG missing"
    fail=1
fi
if ! grep -Eq 'install -d -m 0700 .*/var/lib/ssh' "${DROPIN}" 2>/dev/null; then
    echo "::error file=${DROPIN}::drop-in must create /var/lib/ssh via install -d -m 0700"
    fail=1
fi
[ "${fail}" -eq 0 ] && echo "OK — SSH host keys persistent"
exit "${fail}"
