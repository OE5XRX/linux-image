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
# Scope: only files tracked by git in this repo. `kas dump`/`kas build` clone
# upstream layers (poky, meta-*) into the workspace, and those legitimately use
# --use-uuid — scanning them would be a wall of false positives. `git ls-files`
# ignores them (and build/, downloads/, …); a plain-`find` fallback covers
# non-git trees (e.g. the unit-test temp dirs).
#
# The authoritative check is L0b (a ROOTFS_POSTPROCESS assertion on the built
# fstab); this is the fast early-warning that needs no build.
#
# Usage: l0a-fstab-uuid-lint.sh [repo-root]   (default: .)

set -euo pipefail

root="${1:-.}"
rc=0

# Collect our own wks + recipe files (git-tracked only, else find).
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    mapfile -t wks_files < <(git -C "$root" ls-files -- '*.wks' '*.wks.in' | sed "s|^|${root%/}/|")
    mapfile -t recipe_files < <(git -C "$root" ls-files -- '*.bb' '*.bbappend' | sed "s|^|${root%/}/|")
else
    mapfile -t wks_files < <(find "$root" \( -name '*.wks' -o -name '*.wks.in' \))
    mapfile -t recipe_files < <(find "$root" \( -name '*.bb' -o -name '*.bbappend' \))
fi

# 1) wks mountpoint parts with --use-uuid and no --no-fstab-update.
for wks in "${wks_files[@]}"; do
    [ -f "$wks" ] || continue
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
done

# 2) recipe lines writing a UUID= fstab entry.
for recipe in "${recipe_files[@]}"; do
    [ -f "$recipe" ] || continue
    while IFS= read -r hit; do
        echo "::error file=${recipe}::recipe writes a device-UUID fstab entry (use PARTLABEL): ${hit}"
        rc=1
    done < <(grep -nE 'UUID=|/dev/disk/by-uuid/' "$recipe" 2>/dev/null | grep -i 'fstab' || true)
done

if [[ "$rc" -eq 0 ]]; then
    echo "L0a: no build-unstable UUID mounts found."
fi
exit "$rc"
