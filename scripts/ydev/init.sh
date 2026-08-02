#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=lib.sh disable=SC1091
. "$(dirname "$0")/lib.sh"
if [ -f "${YDEV_ROOT}/.env" ]; then
  echo "ydev: .env already exists — leaving it untouched"
  exit 0
fi
cp "${YDEV_ROOT}/.env.example" "${YDEV_ROOT}/.env"
echo "ydev: wrote .env — fill in STORAGE_BOX_HOST/USER and place ~/.ssh/storagebox, then run: just doctor"
