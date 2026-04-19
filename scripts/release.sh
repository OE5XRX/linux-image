#!/usr/bin/env bash
#
# Release helper for OE5XRX linux-image.
#
# Creates a timestamped git tag in `YYYY.MM.DD-HH` UTC format and pushes
# it to origin. The push triggers `.github/workflows/release.yml`, which
# builds both images (qemux86-64 + raspberrypi4-64), signs them with
# cosign keyless, and publishes a GitHub Release with the artifacts.
#
# Valid tag formats:
#   YYYY.MM.DD-HH        — normal release (default)
#   YYYY.MM.DD-HH[a-z]   — same-hour hotfix, bump the letter each time
#
# The script enforces this shape so a typo can't push a tag that the
# release.yml workflow silently refuses to build.
#
# Usage:
#   scripts/release.sh                  # auto-tag YYYY.MM.DD-HH (UTC)
#   scripts/release.sh --suffix a       # hotfix inside the same UTC hour
#   scripts/release.sh --dry-run        # preview; don't tag or push
#   scripts/release.sh --yes            # skip the confirmation prompt

set -euo pipefail

readonly TAG_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}[a-z]?$'

usage() {
    cat <<EOF
Usage: scripts/release.sh [--suffix <a-z>] [--dry-run] [--yes]

Creates a timestamped tag (UTC, hour granularity) and pushes it.
The release.yml workflow takes over from there.

Options:
  --suffix <letter>  Append a single lowercase letter [a-z] to the base
                     tag. Use this only when a prior release already
                     fired in the same UTC hour (e.g. 2026.04.19-14
                     exists -> --suffix a -> 2026.04.19-14a). Bump the
                     letter if 14a is also taken.
  --dry-run          Print what would happen; make no changes.
  --yes              Skip the interactive confirmation prompt.
  -h, --help         Show this help.
EOF
}

DRY_RUN=0
ASSUME_YES=0
SUFFIX=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    -n | --dry-run) DRY_RUN=1; shift ;;
    -y | --yes) ASSUME_YES=1; shift ;;
    --suffix)
        [[ $# -ge 2 ]] || { echo "--suffix requires a value [a-z]" >&2; exit 2; }
        SUFFIX="$2"
        shift 2
        ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -n "$SUFFIX" ]] && ! [[ "$SUFFIX" =~ ^[a-z]$ ]]; then
    echo "--suffix must be a single lowercase letter [a-z] (got '$SUFFIX')." >&2
    exit 2
fi

branch=$(git symbolic-ref --short HEAD 2>/dev/null || echo "<detached>")
if [[ "$branch" != "main" ]]; then
    echo "Must be on main to release (currently on: $branch)." >&2
    exit 1
fi

# --porcelain surfaces unstaged, staged, and untracked changes — all
# three block a release because the tagged commit should fully match
# what's on origin/main.
if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is not clean. Commit, stash, or ignore first:" >&2
    echo >&2
    git status --short >&2
    exit 1
fi

git fetch origin main --quiet
local_sha=$(git rev-parse HEAD)
remote_sha=$(git rev-parse origin/main)
if [[ "$local_sha" != "$remote_sha" ]]; then
    echo "Local main (${local_sha:0:8}) differs from origin/main (${remote_sha:0:8})." >&2
    echo "Pull first so the tag points at the published HEAD." >&2
    exit 1
fi

base=$(date -u +%Y.%m.%d-%H)
tag="${base}${SUFFIX}"

# Paranoia guard — this should never fire since --suffix is validated
# and `date` emits fixed-width fields, but it keeps the invariant honest.
if ! [[ "$tag" =~ $TAG_RE ]]; then
    echo "Internal error: generated tag '$tag' doesn't match $TAG_RE" >&2
    exit 3
fi

if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null \
    || git ls-remote --tags --exit-code origin "refs/tags/$tag" >/dev/null 2>&1; then
    echo "Tag '$tag' already exists." >&2
    if [[ -z "$SUFFIX" ]]; then
        echo "Re-run with --suffix a for a hotfix in the same UTC hour." >&2
    elif [[ "$SUFFIX" == "z" ]]; then
        echo "Out of suffix letters (you've reached z). Wait for the next UTC hour." >&2
    else
        next=$(printf "%s" "$SUFFIX" | tr 'a-y' 'b-z')
        echo "Re-run with --suffix ${next}." >&2
    fi
    exit 1
fi

last_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)

echo "============================================"
echo "  Tag:     $tag"
echo "  Commit:  $(git rev-parse --short HEAD)  $(git log -1 --format=%s)"
echo "  Since:   ${last_tag:-<no previous tag>}"
echo "============================================"

if [[ -n "$last_tag" ]]; then
    echo
    echo "Commits in this release:"
    git log --pretty=format:"  %h %s" "${last_tag}..HEAD"
    echo
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "(dry run — no tag created, no push)"
    exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
    echo
    read -r -p "Create and push this release? [y/N] " answer
    # Match y/Y/yes/YES/Yes without ${var,,} — that's bash 4+, and
    # macOS still ships bash 3.2 by default.
    case "$answer" in
    [yY] | [yY][eE][sS]) ;;
    *) echo "Aborted."; exit 1 ;;
    esac
fi

git tag -a "$tag" -m "Release $tag"
git push origin "$tag"

echo
echo "Tag pushed. release.yml is now building both images + publishing the release."
echo "Watch: https://github.com/OE5XRX/linux-image/actions"
