# scripts/ydev/lib.sh — shared helpers for ydev recipes. Source, don't exec.
# shellcheck shell=bash
YDEV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIRROR_MNT="${YDEV_MIRROR_MNT:-/mnt/yocto-shared}"

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

mirror_mounted() {  # true if the shared mirror is mounted (test override: YDEV_FORCE_MOUNTED=1)
  [ "${YDEV_FORCE_MOUNTED:-0}" = "1" ] && return 0
  mountpoint -q "$MIRROR_MNT"
}
