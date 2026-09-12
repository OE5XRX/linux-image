#!/usr/bin/env bash
# Push a per-build summary to the Pushgateway (runner-side, if: always()).
# All inputs come from env — never from argv (avoids secret leakage into
# /proc/pid/cmdline and keeps the call site clean in the workflow step).
#
# Required env:
#   SESSION              ydev session label (e.g. ci-<run_id>-<attempt>-<machine>)
#   SUCCESS              1 = build succeeded, 0 = failed
#   DURATION             wall-clock seconds from BUILD_START to push time
#   REF                  git ref (e.g. refs/heads/main, refs/pull/42/merge)
#   MACHINE              kas machine name (e.g. raspberrypi4-64)
#   CF_ACCESS_CLIENT_ID       CF Access service-token id  (must be add-masked)
#   CF_ACCESS_CLIENT_SECRET   CF Access service-token secret (must be add-masked)
#
# Optional env (default 0 when absent or empty):
#   SSTATE_HIT_RATIO     float [0,1] — best-effort, 0 if not derivable on runner
#   IMAGE_BYTES          integer    — best-effort, 0 if no image present
set -euo pipefail

: "${SESSION:?SESSION must be set}"
: "${SUCCESS:?SUCCESS must be set (1 or 0)}"
: "${DURATION:?DURATION must be set}"
: "${REF:?REF must be set}"
: "${MACHINE:?MACHINE must be set}"
: "${CF_ACCESS_CLIENT_ID:?CF_ACCESS_CLIENT_ID must be set}"
: "${CF_ACCESS_CLIENT_SECRET:?CF_ACCESS_CLIENT_SECRET must be set}"

SSTATE="${SSTATE_HIT_RATIO:-0}"
IMG="${IMAGE_BYTES:-0}"

# Escape backslash then double-quote in label values so Prometheus exposition
# is never malformed (a git ref/branch can contain either character).
REF=${REF//\\/\\\\}; REF=${REF//\"/\\\"}
MACHINE=${MACHINE//\\/\\\\}; MACHINE=${MACHINE//\"/\\\"}

body=$(cat <<EOF
# TYPE ydev_build_duration_seconds gauge
ydev_build_duration_seconds{ref="$REF",machine="$MACHINE"} $DURATION
# TYPE ydev_build_success gauge
ydev_build_success{ref="$REF",machine="$MACHINE"} $SUCCESS
# TYPE ydev_build_sstate_hit_ratio gauge
ydev_build_sstate_hit_ratio{ref="$REF",machine="$MACHINE"} $SSTATE
# TYPE ydev_build_image_bytes gauge
ydev_build_image_bytes{ref="$REF",machine="$MACHINE"} $IMG
EOF
)
# The Prometheus text format requires a trailing newline on the final line, but
# $(...) strips trailing newlines — without this the Pushgateway rejects the
# body with HTTP 400 ("text format parsing error").
body+=$'\n'

# Pass CF-Access headers via curl --config on stdin so they never appear in
# /proc/<pid>/cmdline on the runner.  The URL and body stay on argv (not secret).
URL="https://push-gw.oe5xrx.org/metrics/job/ydev_build/instance/$SESSION"
curl -fsS --retry 3 --connect-timeout 10 --max-time 30 --config - --data-binary "$body" "$URL" <<CURLCFG
header = "CF-Access-Client-Id: ${CF_ACCESS_CLIENT_ID}"
header = "CF-Access-Client-Secret: ${CF_ACCESS_CLIENT_SECRET}"
CURLCFG
