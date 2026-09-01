#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env; require_session
# Flexible args in any order: an optional machine + an optional --dev flag.
machine="qemux86-64"; dev=0; both=0
for a in "$@"; do
  case "$a" in
    --both|both)                both=1 ;;
    --dev|dev)                  dev=1 ;;
    qemux86-64|raspberrypi4-64) machine="$a" ;;
    *) die_hint "unknown arg '$a'" "usage: just remote build [qemux86-64|raspberrypi4-64] [--dev|--both]" ;;
  esac
done
[ "$both" = 1 ] && [ "$dev" = 1 ] && die_hint "--both and --dev are mutually exclusive" "pick one"
ip=$(session_ip); ydev_ssh_args
# sync source to the yocto user's home. Honour .gitignore so the kas-cloned
# upstream layers (bitbake/openembedded-core/meta-*) and build caches are NOT
# shipped — sending them without their .git leaves broken trees kas can't fetch;
# kas re-clones them fresh on the box. Plus explicit guards for .git and secrets
# (.env.old isn't gitignored) and belt-and-suspenders build/dist.
run rsync -az --delete \
  --exclude '.git/' --exclude '.worktrees/' --exclude 'build/' --exclude 'dist/' \
  --exclude '.env' --exclude '.env.*' --exclude '.ydev-session' \
  --filter=':- .gitignore' \
  -e "$(ydev_rsh)" "${YDEV_ROOT}/" "root@${ip}:/home/yocto/src/"
rt="${OE5XRX_RELEASE_TAG:-}"
if [ "${YDEV_DRYRUN:-0}" = "1" ]; then
  if [ "$both" = 1 ]; then
    echo "DRYRUN: kas build --target oe5xrx-remotestation-image --target oe5xrx-remotestation-dev-image ${machine}.yml"
  else
    echo "DRYRUN: kas build$([ "$dev" = 1 ] && printf ' --target oe5xrx-remotestation-dev-image') ${machine}.yml"
  fi
  echo "DRYRUN: OE5XRX_RELEASE_TAG=${rt:-<box-default>}"
fi
# base64 the tag across the ssh command line: OpenSSH space-joins the remote argv
# WITHOUT quoting, so a tag with whitespace/metacharacters would re-parse in the
# remote login shell (command injection on the box, which runs as root). base64 is
# metacharacter-free and space-free; the heredoc decodes it back. $machine/$dev/$both
# are validated/0-1, so only the free-form tag needs this. (%q below then guards the
# inner `bash -lc` layer.)
rtb64=$(printf '%s' "$rt" | base64 | tr -d '\n')
run ssh "${YDEV_SSH[@]}" "root@${ip}" bash -s -- "$machine" "$dev" "$both" "$rtb64" <<'EOF'
  set -euo pipefail
  m="$1"; d="${2:-0}"; b="${3:-0}"; rt=$(printf '%s' "${4:-}" | base64 -d); chown -R yocto:yocto /home/yocto/src
  # b=1 -> prod+dev in one invocation; d=1 -> dev only; else prod only.
  if [ "$b" = "1" ]; then
    tgt="--target oe5xrx-remotestation-image --target oe5xrx-remotestation-dev-image"
  elif [ "$d" = "1" ]; then
    tgt="--target oe5xrx-remotestation-dev-image"
  else
    tgt=""
  fi
  # Forward the release tag so BitBake stamps /etc/issue + os-release. oe5xrx.yml
  # lists OE5XRX_RELEASE_TAG in its env: block with a "dev" default, and kas passes
  # the env value through — so ONLY export when non-empty. An empty export would
  # OVERRIDE that "dev" default and produce an empty stamp. %q-escape it (like
  # remote-up.sh does for R2 creds): the tag can come from a free-form
  # workflow_dispatch input, so a quote/newline must not break out of the inner
  # `bash -lc` string.
  rt_export=""
  [ -n "$rt" ] && rt_export="export OE5XRX_RELEASE_TAG=$(printf '%q' "$rt") && "
  sudo -u yocto -H bash -lc "cd ~/src && export PATH=\$HOME/.local/bin:\$PATH && ${rt_export}kas build ${tgt} ${m}.yml"
  # publish new sstate + downloads to R2 (creds written by remote-up.sh).
  # Guard: if r2env is missing (box not provisioned via remote-up), skip the
  # publish with a clear message instead of a confusing "No such file".
  if [ -f /etc/ydev/r2env ]; then
    command -v rclone >/dev/null 2>&1 || apt-get install -y --no-install-recommends rclone
    # shellcheck disable=SC1091
    . /etc/ydev/r2env
    # Export the rclone R2 config once, then reuse it for both uploads.
    # no_check_bucket: bucket-scoped token can't HeadBucket (403); PUT directly.
    export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
           RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true \
           RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_SSTATE_KEY" \
           RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SSTATE_SECRET" \
           RCLONE_CONFIG_R2_REGION=auto \
           RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    rclone copy --transfers 16 --checkers 32 \
      /home/yocto/src/build/sstate-cache/ R2:oe5xrx-yocto-sstate/sstate || true
    rclone copy --transfers 16 --checkers 32 \
      /home/yocto/src/build/downloads/ R2:oe5xrx-yocto-sstate/downloads || true
  else
    echo "no /etc/ydev/r2env — skipping R2 publish (run 'just remote up' first)"
  fi
EOF
echo "remote build done ($machine). Fetch with: just remote download $machine"
