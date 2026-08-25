# scripts/ydev/lib.sh — shared helpers for ydev recipes. Source, don't exec.
# shellcheck shell=bash
: "${YDEV_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

die_hint() {  # <msg> [fix]
  echo "ydev: error: $1" >&2
  [ -n "${2:-}" ] && echo "  → $2" >&2
  exit 1
}

run() {  # dry-run aware: YDEV_DRYRUN=1 prints instead of executing
  if [ "${YDEV_DRYRUN:-0}" = "1" ]; then echo "DRYRUN: $*"; else "$@"; fi
}

load_env() {  # source .env if present (justfile also dotenv-loads; this covers direct calls)
  # shellcheck disable=SC2015,SC1091
  [ -f "${YDEV_ROOT}/.env" ] && { set -a; . "${YDEV_ROOT}/.env"; set +a; } || true
}
