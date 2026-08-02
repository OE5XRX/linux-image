#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail
. "$(dirname "$0")/remote-lib.sh"; load_env; require_env_remote
# Idempotent: reuse a live session box.
if [ -f "$YDEV_SESSION" ] && [ "${YDEV_DRYRUN:-0}" != 1 ]; then
  if hcloud server describe "$(session_id)" >/dev/null 2>&1; then
    echo "session box already up: $(session_id) ($(session_ip))"; exit 0
  fi
  echo "stale .ydev-session — recreating"; rm -f "$YDEV_SESSION"
fi
TYPE="${YDEV_SERVER_TYPE:-ccx43}"; LOC="${YDEV_LOCATION:-fsn1}"; NAME="ydev-session"
OUT=$(run hcloud server create --name "$NAME" --type "$TYPE" --image ubuntu-24.04 \
        --ssh-key "$HCLOUD_SSH_KEY_NAME" --location "$LOC" --label "managed-by=ydev" --output json)
[ "${YDEV_DRYRUN:-0}" = 1 ] && { echo "DRYRUN: hcloud server create --type $TYPE --label managed-by=ydev (would parse id/ip, mount, install watchdog)"; exit 0; }
id=$(jq -r '.server.id' <<<"$OUT"); ip=$(hcloud server ip "$id")
printf '%s %s %s\n' "$id" "$ip" "$(date -u +%FT%TZ)" > "$YDEV_SESSION"
# wait for ssh (mirror build.yml "Wait for SSH")
for _ in $(seq 1 30); do ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$ip" true 2>/dev/null && break; sleep 10; done
# deps + yocto user (verbatim from build.yml "Install Yocto build dependencies" + "Create yocto build user")
ssh "root@$ip" bash -s <<'EOF'
  set -euo pipefail
  sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends gawk wget git diffstat unzip texinfo gcc build-essential \
    chrpath socat cpio python3 python3-pip python3-pexpect xz-utils debianutils iputils-ping python3-git \
    python3-jinja2 python3-subunit zstd liblz4-tool file locales libacl1 sshfs rsync qemu-system-x86 ovmf
  locale-gen en_US.UTF-8
  pip3 install kas --break-system-packages
  id yocto >/dev/null 2>&1 || useradd -m -s /bin/bash yocto
  echo 'yocto ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/yocto
  git config --system --add safe.directory '*'
EOF
# bws-fetch box creds on the LAPTOP (remote=bws), scp key, mount (mirror build.yml Fetch+Mount)
export BWS_SERVER_URL="${BWS_SERVER_URL:-https://vault.bitwarden.eu}"
command -v bws >/dev/null || die_hint "bws CLI missing on this machine" "install bws (needed for the remote backend)"
PROJECT_ID=$(bws project list -o json | jq -r '.[]|select(.name=="oe5xrx-yocto-cache")|.id')
[ -n "$PROJECT_ID" ] || die_hint "BW project oe5xrx-yocto-cache not found" "check BWS_ACCESS_TOKEN read-access"
SECRETS=$(bws secret list -p "$PROJECT_ID" -o json)
BOX_HOST=$(jq -r '.[]|select(.key=="STORAGE_BOX_HOST")|.value' <<<"$SECRETS")
BOX_USER=$(jq -r '.[]|select(.key=="STORAGE_BOX_USER")|.value' <<<"$SECRETS")
KEYFILE=$(umask 077; mktemp); trap 'rm -f "$KEYFILE"' EXIT
jq -r '.[]|select(.key=="STORAGE_BOX_SSH_PRIVKEY")|.value' <<<"$SECRETS" > "$KEYFILE"
ssh "root@$ip" 'install -d -m700 /root/.ssh'
scp "$KEYFILE" "root@$ip:/root/.ssh/storagebox"; rm -f "$KEYFILE"
ssh "root@$ip" bash -s -- "$BOX_USER" "$BOX_HOST" <<'EOF'
  set -euo pipefail
  BOX_USER="$1"; BOX_HOST="$2"
  chmod 600 /root/.ssh/storagebox
  grep -q '^user_allow_other' /etc/fuse.conf || echo 'user_allow_other' >> /etc/fuse.conf
  mkdir -p /mnt/yocto-shared
  sshfs -p 23 -o IdentityFile=/root/.ssh/storagebox,StrictHostKeyChecking=accept-new \
    -o allow_other,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 "${BOX_USER}@${BOX_HOST}:" /mnt/yocto-shared
  mkdir -p /mnt/yocto-shared/sstate /mnt/yocto-shared/downloads
  sudo -u yocto sh -c 'touch /mnt/yocto-shared/downloads/.wtest && rm -f /mnt/yocto-shared/downloads/.wtest' && echo "mirror writable"
EOF
echo "ydev session box up: $id ($ip)"
scp -r "$(dirname "$0")/box" "root@$ip:/tmp/ydev-box"
ssh "root@$ip" bash -s -- "${YDEV_IDLE_MINUTES:-30}" "${YDEV_MAX_HOURS:-4}" "$HCLOUD_TOKEN" <<'EOF'
  set -euo pipefail
  IDLE=$1; MAXH=$2; TOKEN=$3
  curl -fsSL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz -C /usr/local/bin hcloud
  install -d -m700 /etc/ydev /opt/ydev
  printf 'YDEV_IDLE_MINUTES=%s\nHCLOUD_TOKEN=%s\n' "$IDLE" "$TOKEN" > /etc/ydev/env; chmod 600 /etc/ydev/env
  printf '%s' "$TOKEN" > /etc/ydev/token; chmod 600 /etc/ydev/token
  install -m755 /tmp/ydev-box/ydev-watchdog.sh /opt/ydev/ydev-watchdog.sh
  install -m644 /tmp/ydev-box/ydev-idle.service /etc/systemd/system/
  install -m644 /tmp/ydev-box/ydev-idle.timer   /etc/systemd/system/
  systemctl daemon-reload; systemctl enable --now ydev-idle.timer
  # hard max-lifetime: self-delete after MAXH hours no matter what
  systemd-run --on-active="${MAXH}h" --unit=ydev-maxlife \
    /bin/sh -c 'export HCLOUD_TOKEN=$(cat /etc/ydev/token); hcloud server delete $(curl -s http://169.254.169.254/hetzner/v1/metadata/instance-id)'
EOF
echo "auto-teardown armed: idle ${YDEV_IDLE_MINUTES:-30}m, max ${YDEV_MAX_HOURS:-4}h"
