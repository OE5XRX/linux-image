#!/usr/bin/env bash
set -euo pipefail
LAUNCH="meta-oe5xrx-remotestation/recipes-core/dev-agent-mount/files/station-agent-dev-launch"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Case 1: mount present (station_agent/__main__.py exists) → picks mount
mkdir -p "$tmp/station_agent"
touch "$tmp/station_agent/__main__.py"
out=$(STATION_AGENT_DEV_BASE="$tmp" STATION_AGENT_DEV_DRYRUN=1 sh "$LAUNCH")
[ "$out" = "mount:$tmp/station_agent" ] || { echo "FAIL mount-case: got '$out'"; exit 1; }

# Case 2: mount absent → falls back to baked
rm -rf "$tmp/station_agent"
out=$(STATION_AGENT_DEV_BASE="$tmp" STATION_AGENT_DEV_DRYRUN=1 sh "$LAUNCH")
[ "$out" = "baked" ] || { echo "FAIL baked-case: got '$out'"; exit 1; }

echo "PASS: dev-launch selection logic"
