#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091,SC2015
. "$(dirname "$0")/lib.sh"; load_env
KEY="${YDEV_KEY:-${HOME}/.ssh/storagebox}"
if mirror_mounted; then echo "already mounted: $MIRROR_MNT"; exit 0; fi
# shellcheck disable=SC2015
[ -n "${STORAGE_BOX_HOST:-}" ] && [ -n "${STORAGE_BOX_USER:-}" ] || die_hint "STORAGE_BOX_HOST/USER not set in .env" "just init  (then edit .env)"
[ -f "$KEY" ] || die_hint "storagebox key $KEY missing" "save Bitwarden STORAGE_BOX_SSH_PRIVKEY there, chmod 600"
[ "${YDEV_DRYRUN:-0}" = "1" ] || command -v sshfs >/dev/null || die_hint "sshfs not installed" "sudo apt install sshfs"
[ -d "$MIRROR_MNT" ] || run sudo install -d -o "${USER}" "$MIRROR_MNT"
# Box home (host: not :/) on port 23; user-owned mount → no allow_other needed.
run sshfs -p 23 \
  -o IdentityFile="$KEY",StrictHostKeyChecking=accept-new,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \
  "${STORAGE_BOX_USER}@${STORAGE_BOX_HOST}:" "$MIRROR_MNT"
echo "mounted $MIRROR_MNT"
