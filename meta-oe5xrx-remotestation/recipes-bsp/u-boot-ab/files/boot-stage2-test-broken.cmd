# OE5XRX boot STAGE 2 — deliberately BROKEN test variant.
#
# Shipped as /boot/boot-stage2.scr ONLY when OE5XRX_BOOT_TEST="stage2-broken"
# (dev builds only; conf/oe5xrx-boot.inc refuses it in release builds). It does
# not boot: it just prints a marker and falls off the end, so `source` returns
# to stage 1, which boots its frozen fallback tagged oe5xrx.stage2=failed. The
# station-agent's commit gate must then refuse the OTA trial → rollback
# (spec docs/superpowers/specs/2026-11-04-slot-boot-stage2-overlays-design.md
# §7, HW scenario 3).
echo "=== OE5XRX TEST FAULT: boot stage 2 deliberately broken (OE5XRX_BOOT_TEST=stage2-broken) - returning to stage 1 ==="
