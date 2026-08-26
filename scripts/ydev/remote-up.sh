#!/usr/bin/env bash
# shellcheck disable=SC1091
set -euo pipefail
. "$(dirname "$0")/remote-lib.sh"; load_env; require_env_remote
ydev_ssh_args
# Idempotent: reuse a FULLY-provisioned live session box (.ydev-session is only
# written after successful provisioning, so its presence means "ready to build").
if [ -f "$YDEV_SESSION" ] && [ "${YDEV_DRYRUN:-0}" != 1 ]; then
  if hcloud server describe "$(session_id)" >/dev/null 2>&1; then
    echo "session box already up: $(session_id) ($(session_ip))"; exit 0
  fi
  echo "stale .ydev-session — recreating"; rm -f "$YDEV_SESSION"
fi
TYPE="${YDEV_SERVER_TYPE:-ccx43}"; LOC="${YDEV_LOCATION:-fsn1}"; NAME="ydev-session"
IDLE="${YDEV_IDLE_MINUTES:-30}"; MAXH="${YDEV_MAX_HOURS:-4}"
# guard: these land unquoted in the box-side systemd-run/env — a bad value would
# abort teardown-arming under the box's `set -e`, defeating the whole guarantee
[[ "$IDLE" =~ ^[0-9]+$ && "$MAXH" =~ ^[0-9]+$ ]] || die_hint "YDEV_IDLE_MINUTES/YDEV_MAX_HOURS must be integers" "check .env"
BOX_DIR="$(dirname "$0")/box"

# cloud-init user-data: arm the auto-teardown at FIRST BOOT, independent of the
# laptop's SSH provisioning. The box self-deletes on idle (YDEV_IDLE_MINUTES) or
# after YDEV_MAX_HOURS — so a half-provisioned box can never linger and bill.
# The box files are base64-embedded to dodge all heredoc quoting.
# SECURITY: the delete-capable HCLOUD_TOKEN is baked into user-data (readable on
# the box via the metadata endpoint) — the accepted tradeoff for a create-time
# teardown guarantee. The token already lives on the box at /etc/ydev/token.
WD_B64=$(base64 -w0 "$BOX_DIR/ydev-watchdog.sh")
SVC_B64=$(base64 -w0 "$BOX_DIR/ydev-idle.service")
TMR_B64=$(base64 -w0 "$BOX_DIR/ydev-idle.timer")
USERDATA=$(cat <<UD
#!/bin/bash
set -euo pipefail
# retry the hcloud fetch — a transient blip must not abort teardown-arming below
for _ in 1 2 3 4 5; do curl -fsSL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz -C /usr/local/bin hcloud && break || sleep 5; done
install -d -m700 /etc/ydev /opt/ydev
printf 'YDEV_IDLE_MINUTES=%s\nHCLOUD_TOKEN=%s\n' '$IDLE' '$HCLOUD_TOKEN' > /etc/ydev/env; chmod 600 /etc/ydev/env
printf '%s' '$HCLOUD_TOKEN' > /etc/ydev/token; chmod 600 /etc/ydev/token
echo '$WD_B64'  | base64 -d > /opt/ydev/ydev-watchdog.sh; chmod 755 /opt/ydev/ydev-watchdog.sh
echo '$SVC_B64' | base64 -d > /etc/systemd/system/ydev-idle.service
echo '$TMR_B64' | base64 -d > /etc/systemd/system/ydev-idle.timer
systemctl daemon-reload; systemctl enable --now ydev-idle.timer
systemd-run --on-active=${MAXH}h --unit=ydev-maxlife /bin/sh -c 'command -v hcloud >/dev/null 2>&1 || curl -fsSL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz -C /usr/local/bin hcloud; export HCLOUD_TOKEN=\$(cat /etc/ydev/token); while ! hcloud server delete \$(curl -s http://169.254.169.254/hetzner/v1/metadata/instance-id); do sleep 60; done'
UD
)
# test/debug hook: dump the generated user-data and stop (token redacted — the
# dump can end up in CI logs / test failure output)
[ "${YDEV_DUMP_USERDATA:-0}" = 1 ] && { printf '%s\n' "${USERDATA//$HCLOUD_TOKEN/<REDACTED>}"; exit 0; }

OUT=$(run hcloud server create --name "$NAME" --type "$TYPE" --image ubuntu-24.04 \
        --ssh-key "$HCLOUD_SSH_KEY_NAME" --location "$LOC" --label "managed-by=ydev" \
        --user-data-from-file - --output json <<<"$USERDATA")
[ "${YDEV_DRYRUN:-0}" = 1 ] && { echo "DRYRUN: hcloud server create --type $TYPE --label managed-by=ydev --user-data-from-file - (teardown via cloud-init: idle ${IDLE}m/max ${MAXH}h; would parse id/ip, provision R2 creds)"; exit 0; }
id=$(jq -r '.server.id' <<<"$OUT"); ip=$(hcloud server ip "$id")
# fresh per-session host-key pin (new box, possibly a recycled IP)
rm -f "$YDEV_KNOWN_HOSTS"
# wait for ssh (mirror build.yml "Wait for SSH")
for _ in $(seq 1 30); do ssh "${YDEV_SSH[@]}" -o ConnectTimeout=5 "root@$ip" true 2>/dev/null && break; sleep 10; done
# deps + yocto user (verbatim from build.yml "Install Yocto build dependencies" + "Create yocto build user")
ssh "${YDEV_SSH[@]}" "root@$ip" bash -s <<'EOF'
  set -euo pipefail
  sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends gawk wget git diffstat unzip texinfo gcc build-essential \
    chrpath socat cpio python3 python3-pip python3-pexpect xz-utils debianutils iputils-ping python3-git \
    python3-jinja2 python3-subunit zstd liblz4-tool file locales libacl1 rsync rclone qemu-system-x86 ovmf
  locale-gen en_US.UTF-8
  pip3 install kas --break-system-packages
  id yocto >/dev/null 2>&1 || useradd -m -s /bin/bash yocto
  echo 'yocto ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/yocto
  git config --system --add safe.directory '*'
EOF
# bws-fetch R2 publish creds on the LAPTOP, pass them to the session box env
export BWS_SERVER_URL="${BWS_SERVER_URL:-https://vault.bitwarden.eu}"
command -v bws >/dev/null || die_hint "bws CLI missing on this machine" "install bws (needed for the remote backend)"
PROJECT_ID=$(bws project list -o json | jq -r '.[]|select(.name=="oe5xrx-yocto-cache")|.id')
[ -n "$PROJECT_ID" ] || die_hint "BW project oe5xrx-yocto-cache not found" "check BWS_ACCESS_TOKEN read-access"
SECRETS=$(bws secret list -p "$PROJECT_ID" -o json)
R2_KEY=$(jq -r '.[]|select(.key=="R2_SSTATE_KEY")|.value' <<<"$SECRETS")
R2_SECRET=$(jq -r '.[]|select(.key=="R2_SSTATE_SECRET")|.value' <<<"$SECRETS")
[ -n "$R2_KEY" ] || die_hint "R2_SSTATE_KEY not found in bws project oe5xrx-yocto-cache" "check BWS_ACCESS_TOKEN read-access"
[ -n "$R2_SECRET" ] || die_hint "R2_SSTATE_SECRET not found in bws project oe5xrx-yocto-cache" "check BWS_ACCESS_TOKEN read-access"
# Write R2 creds into /etc/ydev/r2env on the box (mode 600).
# Secrets are passed via stdin (never in argv — would be visible in /proc/pid/cmdline).
# Shell-quote the opaque values with printf %q so `. /etc/ydev/r2env` parses
# them back exactly, robust to ANY character (newline/quote/whitespace).
printf 'R2_SSTATE_KEY=%q\nR2_SSTATE_SECRET=%q\nR2_ACCOUNT_ID=cef6b7278fa23b4970442ce3a1dfcb32\n' \
  "$R2_KEY" "$R2_SECRET" \
  | ssh "${YDEV_SSH[@]}" "root@$ip" \
      'install -d -m700 /etc/ydev && umask 077 && cat > /etc/ydev/r2env && chmod 600 /etc/ydev/r2env'
echo "R2 creds written to /etc/ydev/r2env"
# provisioning succeeded → record the session now (a mid-fail leaves no session;
# that box still self-deletes via the cloud-init teardown, or `just remote clean`)
printf '%s %s %s\n' "$id" "$ip" "$(date -u +%FT%TZ)" > "$YDEV_SESSION"
echo "ydev session box up: $id ($ip)"
echo "auto-teardown: armed at boot via cloud-init (idle ${IDLE}m, max ${MAXH}h)"
