#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"; load_env
dev="${1:-}"
if [ -z "$dev" ]; then
  echo "usage: just local flash <device>   (writes the raspberrypi4-64 .wic)"
  echo "removable block devices:"
  lsblk -dno NAME,SIZE,RM,TRAN,MODEL 2>/dev/null | awk '$3==1 {print "  /dev/"$0}' || true
  exit 1
fi
# shellcheck disable=SC2012
WIC=$(ls -1 "${YDEV_ROOT}"/build/tmp/deploy/images/raspberrypi4-64/*.rootfs.wic \
             "${YDEV_ROOT}"/dist/raspberrypi4-64/*.wic 2>/dev/null | head -1 || true)
[ -b "$dev" ] || die_hint "$dev is not a block device"
[ -n "$WIC" ] || die_hint "no raspberrypi4-64 .wic found" "just local build raspberrypi4-64  (or just remote download raspberrypi4-64)"
# refuse the disk that carries / (system disk)
rootdisk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1 || true)
[ -n "$rootdisk" ] && [ "$dev" = "/dev/$rootdisk" ] && die_hint "$dev is the system disk — refusing"
# require removable
[ "$(lsblk -dno RM "$dev" 2>/dev/null || echo 0)" = "1" ] || die_hint "$dev is not removable — refusing (safety)"
echo "About to OVERWRITE $dev with $WIC:"; lsblk "$dev"
read -r -p "Type the device path to confirm: " c
[ "$c" = "$dev" ] || die_hint "confirmation mismatch — aborted"
case "$WIC" in
  *.wic) run sudo dd if="$WIC" of="$dev" bs=4M conv=fsync status=progress ;;
  *) die_hint "unexpected image format: $WIC" "expected a plain .wic" ;;
esac
run sync
echo "flashed $dev"
