# scripts/ydev/remote-lib.sh — remote-backend helpers. Source, don't exec.
# shellcheck shell=bash
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
YDEV_SESSION="${YDEV_ROOT}/.ydev-session"
# shellcheck disable=SC2034
YDEV_LABEL="managed-by=ydev"

# shellcheck disable=SC2015
session_id() { [ -f "$YDEV_SESSION" ] && awk '{print $1}' "$YDEV_SESSION" || true; }
# shellcheck disable=SC2015
session_ip() { [ -f "$YDEV_SESSION" ] && awk '{print $2}' "$YDEV_SESSION" || true; }
require_session() { [ -f "$YDEV_SESSION" ] || die_hint "no ydev session box" "just remote up"; }
require_env_remote() {
  for v in HCLOUD_TOKEN BWS_ACCESS_TOKEN HCLOUD_SSH_KEY_NAME; do
    [ -n "${!v:-}" ] || die_hint "$v not set in .env" "just init  (fill the remote section)"
  done
  command -v hcloud >/dev/null || [ "${YDEV_DRYRUN:-0}" = 1 ] || die_hint "hcloud CLI missing" "install github.com/hetznercloud/cli"
}
box_ssh() { run ssh -o StrictHostKeyChecking=accept-new "root@$(session_ip)" "$@"; }
box_scp() { run scp -o StrictHostKeyChecking=accept-new "$1" "root@$(session_ip):$2"; }
