#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/remote-lib.sh"; load_env; require_session
machine="${1:-qemux86-64}"
case "$machine" in qemux86-64|raspberrypi4-64) ;; *) die_hint "unknown machine '$machine'" "qemux86-64 | raspberrypi4-64";; esac
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
if [ "${YDEV_DRYRUN:-0}" = "1" ]; then
  echo "DRYRUN: kas build ${machine}.yml"
fi
run ssh "${YDEV_SSH[@]}" "root@${ip}" bash -s -- "$machine" <<'EOF'
  set -euo pipefail
  m="$1"; chown -R yocto:yocto /home/yocto/src
  sudo -u yocto -H bash -lc "cd ~/src && export PATH=\$HOME/.local/bin:\$PATH && kas build ${m}.yml"
  # publish new sstate + downloads to R2 (creds written by remote-up.sh).
  # Guard: if r2env is missing (box not provisioned via remote-up), skip the
  # publish with a clear message instead of a confusing "No such file".
  if [ -f /etc/ydev/r2env ]; then
    command -v rclone >/dev/null 2>&1 || apt-get install -y --no-install-recommends rclone
    # shellcheck disable=SC1091
    . /etc/ydev/r2env
    RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
    RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_SSTATE_KEY" \
    RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SSTATE_SECRET" \
    RCLONE_CONFIG_R2_REGION=auto \
    RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.eu.r2.cloudflarestorage.com" \
    rclone copy --transfers 16 --checkers 32 \
      /home/yocto/src/build/sstate-cache/ R2:oe5xrx-yocto-sstate/sstate || true
    RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
    RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_SSTATE_KEY" \
    RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SSTATE_SECRET" \
    RCLONE_CONFIG_R2_REGION=auto \
    RCLONE_CONFIG_R2_ENDPOINT="https://${R2_ACCOUNT_ID}.eu.r2.cloudflarestorage.com" \
    rclone copy --transfers 16 --checkers 32 \
      /home/yocto/src/build/downloads/ R2:oe5xrx-yocto-sstate/downloads || true
  else
    echo "no /etc/ydev/r2env — skipping R2 publish (run 'just remote up' first)"
  fi
EOF
echo "remote build done ($machine). Fetch with: just remote download $machine"
