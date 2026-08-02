#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp .env.example "$tmp/.env.example"
# init creates .env from example when absent
( cd "$tmp" && YDEV_ROOT="$tmp" bash "$OLDPWD/scripts/ydev/init.sh" )
[ -f "$tmp/.env" ] || { echo "FAIL init did not create .env"; exit 1; }
# init does NOT overwrite an existing .env
echo "SENTINEL=1" >> "$tmp/.env"
( cd "$tmp" && YDEV_ROOT="$tmp" bash "$OLDPWD/scripts/ydev/init.sh" )
grep -q SENTINEL "$tmp/.env" || { echo "FAIL init overwrote .env"; exit 1; }
echo "PASS test_init"
