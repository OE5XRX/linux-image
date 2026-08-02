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
  # keep the mirror warm: push new sstate (single-user box → no owner/group/perms)
  sudo -u yocto rsync -a --no-owner --no-group --no-perms --ignore-existing \
    /home/yocto/src/build/sstate-cache/ /mnt/yocto-shared/sstate/ || true
EOF
echo "remote build done ($machine). Fetch with: just remote download $machine"
