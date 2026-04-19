#!/usr/bin/env bash
#
# Release helper for OE5XRX linux-image.
#
# Creates a timestamped git tag in `YYYY.MM.DD-HH` UTC format and pushes
# it to origin. The push triggers `.github/workflows/release.yml`, which
# builds both images (qemux86-64 + raspberrypi4-64), signs them with
# cosign keyless, and publishes a GitHub Release with the artifacts.
#
# Usage:
#   scripts/release.sh                   # auto-tag as UTC YYYY.MM.DD-HH
#   scripts/release.sh --tag 2026.04.19-14b   # override (hotfix inside the same hour)
#   scripts/release.sh --dry-run         # preview; don't tag or push
#   scripts/release.sh --yes             # skip the confirmation prompt

set -euo pipefail

usage() {
    cat <<EOF
Usage: scripts/release.sh [--tag <tag>] [--dry-run] [--yes]

Creates a timestamped tag (UTC, hour granularity) and pushes it.
The release.yml workflow takes over from there.

Options:
  --tag <tag>   Override auto-generated tag. Use this only when you
                need a hotfix in the same hour as a prior release
                (e.g. "2026.04.19-14b").
  --dry-run     Print what would happen; make no changes.
  --yes         Skip the interactive confirmation prompt.
  -h, --help    Show this help.
EOF
}

DRY_RUN=0
ASSUME_YES=0
CUSTOM_TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    -n | --dry-run) DRY_RUN=1; shift ;;
    -y | --yes) ASSUME_YES=1; shift ;;
    --tag)
        [[ $# -ge 2 ]] || { echo "--tag requires a value" >&2; exit 2; }
        CUSTOM_TAG="$2"
        shift 2
        ;;
    -h | --help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

command -v gh >/dev/null 2>&1 || {
    echo "This script expects the 'gh' CLI (only to check auth state)." >&2
    exit 1
}

branch=$(git symbolic-ref --short HEAD)
if [[ "$branch" != "main" ]]; then
    echo "Must be on main to release (currently on: $branch)." >&2
    exit 1
fi

if ! git diff-index --quiet HEAD --; then
    echo "Working tree is not clean. Commit or stash first." >&2
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

if [[ -n "$CUSTOM_TAG" ]]; then
    tag="$CUSTOM_TAG"
    # Same charset as OE5XRX_RELEASE_TAG in the image recipe — anything
    # outside that range breaks os-release parsing downstream.
    if ! [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]]; then
        echo "Custom tag '$tag' contains characters outside [A-Za-z0-9._-]." >&2
        exit 1
    fi
else
    tag=$(date -u +%Y.%m.%d-%H)
fi

if git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null; then
    echo "Tag '$tag' already exists locally." >&2
    echo "For a hotfix inside the same hour, re-run with --tag ${tag}b." >&2
    exit 1
fi

if git ls-remote --tags --exit-code origin "refs/tags/$tag" >/dev/null 2>&1; then
    echo "Tag '$tag' already exists on origin." >&2
    echo "For a hotfix inside the same hour, re-run with --tag ${tag}b." >&2
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
    case "${answer,,}" in
    y | yes) ;;
    *) echo "Aborted."; exit 1 ;;
    esac
fi

git tag -a "$tag" -m "Release $tag"
git push origin "$tag"

echo
echo "Tag pushed. release.yml is now building both images + publishing the release."
echo "Watch: gh run watch --repo OE5XRX/linux-image \$(gh run list --repo OE5XRX/linux-image --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')"
