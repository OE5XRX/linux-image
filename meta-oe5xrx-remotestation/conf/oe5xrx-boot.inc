# Single source of truth for the CM4 two-stage boot build knobs (spec
# docs/superpowers/specs/2026-11-04-slot-boot-stage2-overlays-design.md).
#
# Consumed via `require conf/oe5xrx-boot.inc` by BOTH
#   - u-boot-ab           (bakes the overlay list into /boot/boot-stage2.scr)
#   - oe5xrx-dt-overlays  (installs /boot/overlays/<name>.dtbo for that list)
# so stage 2 never names an overlay the rootfs does not carry (and vice versa).
#
# OE5XRX_DT_OVERLAYS  space-separated overlay names, applied in order by stage 2
#                     from /boot/overlays/<name>.dtbo onto a COPY of the
#                     firmware DTB. Each name needs files/<name>-overlay.dts in
#                     oe5xrx-dt-overlays. Names must match [a-z0-9-]+ (they end
#                     up in a hush for-loop, a file path and the kernel cmdline).
#                     Our OWN overlays live only here (in the slot, OTA-able) —
#                     never as dtoverlay= in config.txt.
#                     NEVER machine-override OE5XRX_DT_OVERLAYS (no `_rpi`/`:cm4`
#                     suffixes): u-boot-ab is allarch, so a per-machine value
#                     would desync it from the MACHINE_ARCH oe5xrx-dt-overlays.
#                     Names starting with "oe5xrx-test-" are refused in release
#                     builds (OE5XRX_RELEASE_TAG != "dev"), also when set here
#                     directly instead of via OE5XRX_BOOT_TEST.
#
# OE5XRX_BOOT_TEST    fault-injection switch for the HW boot tests (spec §7,
#                     scenarios 2–4). DEV BUILDS ONLY — a CM4 release build
#                     (OE5XRX_RELEASE_TAG != "dev") carrying it fails to parse.
#                     (On non-CM4 machines such as qemux86-64 both consuming
#                     recipes are skipped via COMPATIBLE_MACHINE, so the switch
#                     is neither applied nor checked there.)
#                     Set via the kas overlays include/boot-test-*.yml, e.g.
#                       kas build raspberrypi4-64.yml:include/boot-test-marker.yml
#   ""                normal build
#   marker            list += oe5xrx-test-marker (harmless property on "/")
#   overlay-broken    list += oe5xrx-test-broken (unresolvable label → stage 2
#                     boots WITHOUT overlays, oe5xrx.overlays=failed:…)
#   stage2-broken     /boot/boot-stage2.scr only echoes and returns → stage 1
#                     boots its fallback with oe5xrx.stage2=failed
#
# Derived (set at parse time by the anonymous function below; the recipes put
# them in their task signatures via vardeps):
#   OE5XRX_DT_OVERLAYS_EFFECTIVE  "a b"   (list incl. test overlay)
#   OE5XRX_DT_OVERLAYS_CSV        "a,b"
#   OE5XRX_OVERLAYS_BOOTARG       " oe5xrx.overlays=ok:a,b" ("" if no overlays)
# These mirror tests/ota-integration/boot_scripts.py render_stage2 exactly
# (tests/ota-integration/test_boot_recipes_static.py runs this function).

OE5XRX_DT_OVERLAYS ??= "oe5xrx-ina226"
OE5XRX_BOOT_TEST ??= ""
# Same weak default as the image recipe: kas passes the real tag from the env
# (oe5xrx.yml `env:`), local builds are "dev".
OE5XRX_RELEASE_TAG ??= "dev"

def oe5xrx_boot_config(d):
    import re
    test_extra = {
        "": [],
        "marker": ["oe5xrx-test-marker"],
        "overlay-broken": ["oe5xrx-test-broken"],
        "stage2-broken": [],
    }
    test = d.getVar("OE5XRX_BOOT_TEST") or ""
    if test not in test_extra:
        bb.fatal("OE5XRX_BOOT_TEST=%r is not one of %s" % (
            test, sorted(k for k in test_extra if k)))
    tag = d.getVar("OE5XRX_RELEASE_TAG") or "dev"
    if test and tag != "dev":
        bb.fatal("OE5XRX_BOOT_TEST=%r is a dev-only fault-injection switch, "
                 "but OE5XRX_RELEASE_TAG=%r - refusing to build a release "
                 "with a deliberately broken boot path." % (test, tag))
    names = (d.getVar("OE5XRX_DT_OVERLAYS") or "").split() + test_extra[test]
    for name in names:
        if not re.fullmatch(r"[a-z0-9-]+", name):
            bb.fatal("OE5XRX_DT_OVERLAYS: invalid overlay name %r "
                     "(allowed: [a-z0-9-]+)" % name)
    test_names = [n for n in names if n.startswith("oe5xrx-test-")]
    if test_names and tag != "dev":
        bb.fatal("OE5XRX_DT_OVERLAYS: test overlay(s) %s in a release build "
                 "(OE5XRX_RELEASE_TAG=%r) - dev builds only." % (test_names, tag))
    if len(set(names)) != len(names):
        bb.fatal("OE5XRX_DT_OVERLAYS: duplicate overlay in %r" % names)
    csv = ",".join(names)
    return {
        "OE5XRX_DT_OVERLAYS_EFFECTIVE": " ".join(names),
        "OE5XRX_DT_OVERLAYS_CSV": csv,
        "OE5XRX_OVERLAYS_BOOTARG": (" oe5xrx.overlays=ok:" + csv) if names else "",
    }

python __anonymous() {
    for key, value in oe5xrx_boot_config(d).items():
        d.setVar(key, value)
}
