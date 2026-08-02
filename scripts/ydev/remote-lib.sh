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
# ssh identity: TOFU host key + optional explicit key (HCLOUD_SSH_KEY, ~ expanded).
# ssh only auto-tries default key names / agent keys; HCLOUD_SSH_KEY points at the
# private half of HCLOUD_SSH_KEY_NAME when it isn't your ssh default.
# ydev_ssh_args populates the YDEV_SSH array (call after load_env, before ssh/scp).
YDEV_SSH=(-o StrictHostKeyChecking=accept-new)
# expand a leading literal "~/" (as stored in .env) to $HOME
ydev_expand_key() { local k="${HCLOUD_SSH_KEY:-}"; [ "${k#\~/}" != "$k" ] && k="${HOME}/${k#\~/}"; printf '%s' "$k"; }
ydev_ssh_args() {
  YDEV_SSH=(-o StrictHostKeyChecking=accept-new)
  local key; key="$(ydev_expand_key)"
  [ -n "$key" ] && YDEV_SSH+=(-o IdentitiesOnly=yes -i "$key")
  return 0  # never let the trailing test's exit status trip `set -e` in callers
}
# same identity handling as a single string for rsync -e
ydev_rsh() {
  local rsh="ssh -o StrictHostKeyChecking=accept-new" key; key="$(ydev_expand_key)"
  [ -n "$key" ] && rsh="$rsh -o IdentitiesOnly=yes -i $key"
  printf '%s' "$rsh"
}
box_ssh() { ydev_ssh_args; run ssh "${YDEV_SSH[@]}" "root@$(session_ip)" "$@"; }
box_scp() { ydev_ssh_args; run scp "${YDEV_SSH[@]}" "$1" "root@$(session_ip):$2"; }
