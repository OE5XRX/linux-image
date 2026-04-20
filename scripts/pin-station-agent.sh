#!/usr/bin/env bash
#
# Update the station-agent lock in the Yocto recipe.
#
# The recipe's SRCREV is treated as a lockfile — similar to a git
# submodule's recorded commit, or the "resolved" field in package-lock.json.
# It always points at a specific station-manager commit, never at a
# moving branch via ${AUTOREV}. Bumping to a newer agent is a normal
# commit like any other dependency bump.
#
# This script resolves a SHA (either main@HEAD by default, or one you
# pass explicitly) and rewrites the SRCREV line. Commit the result.
#
# Usage:
#   scripts/pin-station-agent.sh                   # lock to latest main HEAD
#   scripts/pin-station-agent.sh <sha>             # lock to a specific SHA
#   scripts/pin-station-agent.sh --dry-run         # preview; no file writes

set -euo pipefail

readonly RECIPE="meta-oe5xrx-remotestation/recipes-core/station-agent/station-agent_0.1.0.bb"
readonly UPSTREAM="https://github.com/OE5XRX/station-manager.git"
readonly BRANCH="main"

usage() {
    cat <<EOF
Usage: scripts/pin-station-agent.sh [<sha>] [-n | --dry-run]

Rewrites SRCREV in the station-agent Yocto recipe to a specific commit.
The recipe is treated as a lockfile — a real SHA is always committed.

Arguments:
  <sha>              Full 40-char SHA. Defaults to HEAD of
                     OE5XRX/station-manager@${BRANCH}.

Options:
  -n, --dry-run      Print the resulting recipe change; don't modify files.
  -h, --help         Show this help.
EOF
}

DRY_RUN=0
EXPLICIT_SHA=""

while [[ $# -gt 0 ]]; do
    case "$1" in
    -n | --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *)
        if [[ -n "$EXPLICIT_SHA" ]]; then
            echo "Only one SHA argument allowed." >&2
            exit 2
        fi
        EXPLICIT_SHA="$1"
        shift
        ;;
    esac
done

if [[ ! -f "$RECIPE" ]]; then
    echo "Recipe not found: $RECIPE" >&2
    echo "Run from the repo root." >&2
    exit 1
fi

if [[ -n "$EXPLICIT_SHA" ]]; then
    if ! [[ "$EXPLICIT_SHA" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "SHA must be a full 40-char hex string." >&2
        echo "Got: $EXPLICIT_SHA" >&2
        exit 2
    fi
    # Normalize to lowercase so the recipe stays consistent regardless
    # of where the user copy-pasted the SHA from. `tr` keeps this
    # compatible with bash 3.2 (macOS), ${var,,} wouldn't.
    sha=$(printf '%s' "$EXPLICIT_SHA" | tr 'A-F' 'a-f')
else
    echo "Resolving ${BRANCH} HEAD of ${UPSTREAM} ..." >&2
    sha=$(git ls-remote "$UPSTREAM" "refs/heads/${BRANCH}" | awk '{print $1}')
    if [[ -z "$sha" ]]; then
        echo "Failed to resolve ${BRANCH} HEAD of ${UPSTREAM}." >&2
        exit 1
    fi
fi
new_line="SRCREV = \"${sha}\""

current_line=$(grep -E '^SRCREV[[:space:]]*=' "$RECIPE" || true)
if [[ -z "$current_line" ]]; then
    echo "No SRCREV line found in $RECIPE — unexpected recipe layout." >&2
    exit 1
fi

echo "Before: ${current_line}"
echo "After:  ${new_line}"

if [[ "$current_line" == "$new_line" ]]; then
    echo "(no change — already locked to this SHA)"
    exit 0
fi

if [[ $DRY_RUN -eq 1 ]]; then
    echo
    echo "(dry run — no changes written)"
    exit 0
fi

# In-place edit without GNU vs BSD sed headaches. Only the first match is
# rewritten, which is the top-of-file SRCREV assignment.
# Pass an explicit template — `mktemp` without one works on GNU coreutils
# but fails on BSD/macOS, and we claim bash 3.2 compatibility elsewhere
# in this script.
tmp=$(mktemp "${TMPDIR:-/tmp}/pin-station-agent.XXXXXX")
trap 'rm -f "$tmp"' EXIT
awk -v new="$new_line" '
    !done && /^SRCREV[[:space:]]*=/ { print new; done=1; next }
    { print }
' "$RECIPE" > "$tmp"
# Write back via redirection to the existing recipe path so the file's
# tracked mode (0644) is preserved. `mv "$tmp" "$RECIPE"` would replace
# $RECIPE with the tmp file's 0600 mode and flip git's recorded mode.
cat "$tmp" > "$RECIPE"

echo
echo "Recipe updated. Diff:"
git --no-pager diff -- "$RECIPE" | sed 's/^/  /'
echo
echo "Next: commit the lock bump."
echo "  git add $RECIPE"
echo "  git commit -m \"Bump station-agent to ${sha:0:8}\""
