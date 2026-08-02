#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"; load_env
fail=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "MISS $1 — $3"; fail=1; fi; }
echo "== ydev doctor =="
# shellcheck disable=SC2016
chk "just >= 1.31"      'v=$(just --version | grep -oE "[0-9]+\.[0-9]+" | head -1); [ "$(printf "%s\n1.31" "$v" | sort -V | head -1)" = "1.31" ]' "install/upgrade just"
chk "kas"               'command -v kas'                         "pip install kas"
chk "sshfs"             'command -v sshfs'                       "sudo apt install sshfs"
# shellcheck disable=SC2016
chk ".env present"      '[ -f "${YDEV_ROOT}/.env" ]'            "just init"
# shellcheck disable=SC2016
chk "STORAGE_BOX_HOST"  '[ -n "${STORAGE_BOX_HOST:-}" ]'        "set it in .env"
# shellcheck disable=SC2016
chk "STORAGE_BOX_USER"  '[ -n "${STORAGE_BOX_USER:-}" ]'        "set it in .env"
# shellcheck disable=SC2016
chk "box key"           '[ -f "${HOME}/.ssh/storagebox" ]'      "put STORAGE_BOX_SSH_PRIVKEY there (chmod 600)"
# remote extras are optional here (Plan B); report as info only
for t in hcloud bws; do command -v "$t" >/dev/null 2>&1 && echo "ok   $t (remote)" || echo "info $t not installed (only needed for 'just remote …')"; done
# shellcheck disable=SC2015
[ "$fail" = 0 ] && echo "doctor: local loop ready" || { echo "doctor: fix the MISS items above"; exit 1; }
