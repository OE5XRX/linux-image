#!/usr/bin/env bash
#
# Compute the next OE5XRX linux-image release version in YYYY.MM.DD-HH[a-z]
# (UTC hour) form, bumping a lowercase-letter suffix when the base hour is
# already taken. Prints the version to stdout.
#
# This replaces the local scripts/release.sh version computation: the release
# is now a one-button workflow_dispatch that computes its own version (mirrors
# FW-RemoteStation). Wrapped by .github/actions/compute-version.
#
# Usage:
#   compute-release-version.sh                     # base = now (UTC), existing = git tags
#   compute-release-version.sh --now 2026.07.11-15 # inject base (for tests)
#   compute-release-version.sh --existing "<nl-list>"  # inject existing tags (for tests)

set -euo pipefail

readonly TAG_RE='^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}[a-z]?$'

now=""
existing=""
have_existing=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --now)
            [[ $# -ge 2 ]] || { echo "--now requires a value (YYYY.MM.DD-HH)" >&2; exit 2; }
            now="$2"; shift 2 ;;
        --existing)
            [[ $# -ge 2 ]] || { echo "--existing requires a value (newline-separated tags)" >&2; exit 2; }
            existing="$2"; have_existing=1; shift 2 ;;
        -h|--help)  sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

base="${now:-$(date -u +%Y.%m.%d-%H)}"

if [[ "${have_existing}" -eq 0 ]]; then
    existing="$(git tag -l "${base}*" || true)"
fi

# Membership test against the newline-separated existing list.
_exists() {
    printf '%s\n' "${existing}" | grep -Fxq "$1"
}

if ! _exists "${base}"; then
    version="${base}"
else
    version=""
    for letter in {a..z}; do
        cand="${base}${letter}"
        if ! _exists "${cand}"; then
            version="${cand}"
            break
        fi
    done
    if [[ -z "${version}" ]]; then
        echo "::error::all same-hour suffixes a-z for ${base} are taken" >&2
        exit 1
    fi
fi

if ! printf '%s' "${version}" | grep -Eq "${TAG_RE}"; then
    echo "::error::computed version '${version}' is not a valid tag" >&2
    exit 1
fi

printf '%s\n' "${version}"
