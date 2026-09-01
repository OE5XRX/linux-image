#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; export YDEV_ROOT="$tmp"
# no session -> hint
if err=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh 2>&1); then echo "FAIL should exit"; exit 1; fi
echo "$err" | grep -q "just remote up" || { echo "FAIL hint: $err"; exit 1; }
# with session -> dry-run rsync (excludes build/) + kas build as yocto
printf '1 1.2.3.4 t\n' > "$tmp/.ydev-session"
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh raspberrypi4-64 2>&1)
echo "$out" | grep -q "rsync" && echo "$out" | grep -q -- "--exclude" || { echo "FAIL rsync: $out"; exit 1; }
echo "$out" | grep -q -- "--filter=:- .gitignore" || { echo "FAIL gitignore filter (kas layers must be excluded): $out"; exit 1; }
echo "$out" | grep -q "kas build raspberrypi4-64.yml" || { echo "FAIL kas: $out"; exit 1; }
# --dev flag -> dev-image target in the dry-run kas line (machine still optional)
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh --dev 2>&1)
echo "$out" | grep -q -- "kas build --target oe5xrx-remotestation-dev-image qemux86-64.yml" \
  || { echo "FAIL dev target: $out"; exit 1; }
# --both -> prod AND dev target in one kas invocation (CI dev_image=true path)
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh --both 2>&1)
echo "$out" | grep -q -- "kas build --target oe5xrx-remotestation-image --target oe5xrx-remotestation-dev-image qemux86-64.yml" \
  || { echo "FAIL both targets: $out"; exit 1; }
# --both with an explicit machine still works
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh raspberrypi4-64 --both 2>&1)
echo "$out" | grep -q -- "kas build --target oe5xrx-remotestation-image --target oe5xrx-remotestation-dev-image raspberrypi4-64.yml" \
  || { echo "FAIL both targets rpi: $out"; exit 1; }
# --both and --dev are mutually exclusive
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh --both --dev 2>&1) || true
echo "$out" | grep -q "mutually exclusive" || { echo "FAIL both+dev guard (output: $out)"; exit 1; }
# dry-run prints the remote ssh command but the heredoc body runs on the box (not locally),
# so rclone assertions are on the script content rather than dry-run output
grep -q "rclone copy" scripts/ydev/remote-build.sh || { echo "FAIL rclone publish missing in script"; exit 1; }
grep -q "oe5xrx-yocto-sstate/sstate" scripts/ydev/remote-build.sh || { echo "FAIL R2 sstate bucket prefix missing"; exit 1; }
grep -q "oe5xrx-yocto-sstate/downloads" scripts/ydev/remote-build.sh || { echo "FAIL R2 downloads bucket prefix missing"; exit 1; }
grep -q "R2_SSTATE_KEY" scripts/ydev/remote-build.sh || { echo "FAIL R2_SSTATE_KEY missing"; exit 1; }
grep -q "rclone copy" scripts/ydev/remote-build.sh && ! grep -qF "mnt/" scripts/ydev/remote-build.sh || { echo "FAIL old mount path or missing rclone"; exit 1; }
# release-tag passthrough into the box kas env (parity with old build.yml stamping)
# explicit tag is surfaced in the dryrun and forwarded verbatim
out=$(OE5XRX_RELEASE_TAG=2026.09.01-07 YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh 2>&1)
echo "$out" | grep -q "OE5XRX_RELEASE_TAG=2026.09.01-07" || { echo "FAIL release tag not forwarded in dryrun: $out"; exit 1; }
# unset tag -> box default marker (empty stays empty; oe5xrx.yml default applies on the box)
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh 2>&1)
echo "$out" | grep -q "OE5XRX_RELEASE_TAG=<box-default>" || { echo "FAIL box-default tag marker missing: $out"; exit 1; }
# belt: the actual export into the yocto kas env is present in the script body
grep -q "export OE5XRX_RELEASE_TAG" scripts/ydev/remote-build.sh || { echo "FAIL export missing"; exit 1; }
# the tag is %q-escaped before the box bash -lc (injection-safe; free-form dispatch input)
grep -q 'printf .%q. "$rt"' scripts/ydev/remote-build.sh || { echo "FAIL release tag not %q-escaped"; exit 1; }
grep -qF "OE5XRX_RELEASE_TAG='\${rt}'" scripts/ydev/remote-build.sh && { echo "FAIL raw unescaped tag interpolation still present"; exit 1; }
# empty tag must NOT be exported (an empty export overrides oe5xrx.yml's "dev" default)
grep -q '\[ -n "$rt" \] && rt_export=' scripts/ydev/remote-build.sh || { echo "FAIL empty tag not guarded — would override box default"; exit 1; }
# the tag crosses the ssh command line base64-encoded (ssh space-joins argv unquoted -> injection)
grep -q 'base64' scripts/ydev/remote-build.sh || { echo "FAIL tag not base64-encoded across ssh boundary"; exit 1; }
grep -qF 'bash -s -- "$machine" "$dev" "$both" "$rt"' scripts/ydev/remote-build.sh && { echo "FAIL raw tag still passed as ssh arg"; exit 1; }
echo "PASS test_remote_build"
