#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env
if [ ! -f "$YDEV_SESSION" ]; then echo "no ydev session (just remote up)"; exit 0; fi
id=$(session_id); ip=$(session_ip); started=$(awk '{print $3}' "$YDEV_SESSION")
echo "session box: id=$id ip=$ip started=$started"
run hcloud server describe "$id" -o 'format={{.Status}} {{.ServerType.Name}} {{.Datacenter.Location.Name}}' 2>/dev/null || echo "(hcloud describe failed — box may be gone; run just remote clean)"
echo "mirror on box:"; box_ssh 'mountpoint -q /mnt/yocto-shared && echo mounted || echo NOT-mounted' 2>/dev/null || true
