#!/usr/bin/env bash
#
# L0a static guard (runs on every PR, seconds): fail if the build could ever
# mount a filesystem by a build-unstable device UUID. That is exactly the bug
# class of #37 (ESP mounted by FAT UUID → OTA'd slot mismatched → emergency
# mode). Only PARTLABEL / LABEL / cmdline-root are OTA-safe.
#
# Flags:
#   1. a wks `part <mountpoint> ... --use-uuid` WITHOUT `--no-fstab-update`
#      (wic would inject a UUID= fstab line for that mount)
#   2. a recipe line that writes a `UUID=` entry into /etc/fstab
#
# The authoritative check is L0b (a ROOTFS_POSTPROCESS assertion on the built
# fstab); this is the fast early-warning that needs no build.
#
# Usage: l0a-fstab-uuid-lint.sh [repo-root]   (default: .)

set -euo pipefail

root="${1:-.}"
rc=0

# 1) wks mountpoint parts with --use-uuid and no --no-fstab-update.
while IFS= read -r wks; do
    lineno=0
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        # A mountpoint part: "part /<something> ...". Parts without a mountpoint
        # ("part --ondisk ...") never get an fstab entry, so they are exempt.
        case "$line" in
            part[[:space:]]*/*)
                if printf '%s' "$line" | grep -q -- '--use-uuid' \
                   && ! printf '%s' "$line" | grep -q -- '--no-fstab-update'; then
                    echo "::error file=${wks},line=${lineno}::mountpoint part uses --use-uuid without --no-fstab-update (build-unstable UUID mount; use PARTLABEL)"
                    rc=1
                fi
                ;;
        esac
    done < "$wks"
done < <(find "$root" -name '*.wks' -o -name '*.wks.in' 2>/dev/null)

# 2) recipe lines writing a UUID= fstab entry.
while IFS= read -r hit; do
    echo "::error::recipe writes a UUID= fstab entry (use PARTLABEL): ${hit}"
    rc=1
done < <(grep -rInE 'UUID=' --include='*.bb' --include='*.bbappend' "$root" 2>/dev/null \
         | grep -i 'fstab' || true)

if [[ "$rc" -eq 0 ]]; then
    echo "L0a: no build-unstable UUID mounts found."
fi
exit "$rc"
