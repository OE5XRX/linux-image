"""Behaviour tests for the two-stage CM4 boot in a U-Boot v2026.01 sandbox.

The REAL stage-1 (boot.cmd) and stage-2 (boot-stage2.cmd.in, rendered like
the u-boot-ab recipe) texts run in the sandbox against a GPT disk with the
wks partition layout, the real CM4 firmware DTB at ${fdt_addr} and the real
overlays (dtc -@). Only booti/wdt/reset/saveenv and the boot device are
rewritten (uboot_sandbox.rewrite_for_sandbox). Not covered (HW test): GPU
firmware/config.txt, a real kernel start, the watchdog itself.

Needs UBOOT_SANDBOX + CM4_BASE_DTB (see uboot_sandbox.py); skipped locally
without them, a hard failure in CI. Marker `sandbox` (CI job uboot-sandbox).
"""

from __future__ import annotations

import os
import re
import subprocess
from pathlib import Path

import pytest
from boot_scripts import read_stage1, read_stage2_template, render_stage2
from uboot_sandbox import (
    FDT_ADDR,
    FDT_ADDR_R,
    KERNEL_ADDR_R,
    BootiReject,
    SandboxUnavailable,
    make_test_disk,
    compile_dtbo,
    rewrite_for_sandbox,
    run_boot,
    sandbox_paths,
    script_bytes,
)

pytestmark = pytest.mark.sandbox

_REPO = Path(__file__).resolve().parents[2]
_OVERLAY_DIR = (_REPO / "meta-oe5xrx-remotestation" / "recipes-bsp"
                / "oe5xrx-dt-overlays" / "files")
I2C1 = "/soc/i2c@7e804000"
INA = "oe5xrx-ina226"
BROKEN = "oe5xrx-test-broken"
MARKER = "oe5xrx-test-marker"


# --- fixtures / helpers -----------------------------------------------------

@pytest.fixture(scope="session")
def sbx():
    try:
        uboot, mkimage, dtb = sandbox_paths()
    except SandboxUnavailable as e:
        if os.environ.get("CI"):
            pytest.fail(f"U-Boot sandbox unavailable in CI: {e}")
        pytest.skip(f"U-Boot sandbox unavailable: {e}")
    return {"uboot": uboot, "mkimage": mkimage, "dtb": dtb}


@pytest.fixture(scope="session")
def dtbos(sbx):
    return {name: compile_dtbo(_OVERLAY_DIR / f"{name}-overlay.dts")
            for name in (INA, BROKEN, MARKER)}


def kernel(slot: str) -> bytes:
    head = f"KERNEL-SLOT-{slot.upper()}...".encode()
    assert len(head) == 16
    return head + b"\0" * 4080


def stage2_scr(sbx, overlays: list[str]) -> bytes:
    text = render_stage2(read_stage2_template(), overlays)
    return script_bytes(rewrite_for_sandbox(text, stage1=False),
                        sbx["mkimage"])


def slot_files(sbx, slot: str, *, stage2: bytes | None,
               overlays: dict[str, bytes] | None = None) -> dict[str, bytes]:
    files = {"/boot/Image": kernel(slot)}
    if stage2 is not None:
        files["/boot/boot-stage2.scr"] = stage2
    for name, blob in (overlays or {}).items():
        files[f"/boot/overlays/{name}.dtbo"] = blob
    return files


def standard_slots(sbx, dtbos, overlays: list[str],
                   shipped: list[str] | None = None):
    """Both slots with stage 2 rendered for `overlays`; `shipped` = overlay
    files present in the slot (default: all listed that exist)."""
    if shipped is None:
        shipped = [o for o in overlays if o in dtbos]
    s2 = stage2_scr(sbx, overlays)
    ov = {o: dtbos[o] for o in shipped}
    return {s: slot_files(sbx, s, stage2=s2, overlays=ov) for s in ("a", "b")}


def boot(sbx, tmp_path: Path, slots, env=None, name="boot", **kw):
    disk = tmp_path / "disk.img"
    if not disk.exists():
        make_test_disk(disk, slots)
    return run_boot(tmp_path / name, disk, read_stage1(), sbx["dtb"],
                    env or {}, uboot=sbx["uboot"], mkimage=sbx["mkimage"],
                    **kw)


# Rootfs DTB paths of stage 1's last-resort fallback, in boot.cmd order.
ROOTFS_DTB_BROADCOM = "/boot/broadcom/bcm2711-rpi-cm4.dtb"
ROOTFS_DTB_PLAIN = "/boot/bcm2711-rpi-cm4.dtb"


def rootfs_dtb(tag: str) -> bytes:
    """A small valid DTB, distinguishable by its /oe5xrx,rootfs-dtb tag."""
    dts = ('/dts-v1/;\n/ { compatible = "oe5xrx,test"; '
           f'oe5xrx,rootfs-dtb = "{tag}"; }};\n')
    return subprocess.run(["dtc", "-q", "-I", "dts", "-O", "dtb"],
                          input=dts.encode(), check=True,
                          capture_output=True, timeout=30).stdout


def node_exists(dtb: Path, node: str) -> bool:
    return subprocess.run(["fdtget", "-p", str(dtb), node],
                          capture_output=True, timeout=30).returncode == 0


def prop(dtb: Path, node: str, name: str) -> str | None:
    r = subprocess.run(["fdtget", str(dtb), node, name],
                       capture_output=True, text=True, timeout=30)
    return r.stdout.strip() if r.returncode == 0 else None


def marker(bootargs: str, key: str) -> list[str]:
    return re.findall(rf"(?:^| ){re.escape(key)}=(\S*)", bootargs)


def assert_booted(r, slot: str):
    assert r.booted, r.output
    assert not r.reset, r.output
    assert r.kernel == kernel(slot)[:16], r.output
    assert f"root=PARTLABEL=root_{slot} " in r.bootargs, r.bootargs
    assert r.booti_kernel_addr == KERNEL_ADDR_R


def assert_base_untouched(sbx, r):
    assert r.fdt_addr_after is not None
    assert r.fdt_addr_after.read_bytes() == sbx["dtb"].read_bytes()


def assert_no_overlay_applied(r):
    assert r.fdt_path is not None
    assert prop(r.fdt_path, "/", "compatible") is not None  # valid tree
    assert node_exists(r.fdt_path, I2C1)
    assert not node_exists(r.fdt_path, f"{I2C1}/ina226@40")
    assert not node_exists(r.fdt_path, f"{I2C1}/ina226@41")
    assert prop(r.fdt_path, "/", "oe5xrx,test-marker") is None


# --- tests ------------------------------------------------------------------

def test_normal_boot_applies_slot_overlay(sbx, dtbos, tmp_path):
    r = boot(sbx, tmp_path, standard_slots(sbx, dtbos, [INA]))
    assert_booted(r, "a")
    assert marker(r.bootargs, "oe5xrx.stage2") == ["ok"]
    assert marker(r.bootargs, "oe5xrx.overlays") == [f"ok:{INA}"]
    assert r.booti_fdt_addr == FDT_ADDR_R  # the copy, not the firmware DTB
    for addr in ("40", "41"):
        assert prop(r.fdt_path, f"{I2C1}/ina226@{addr}",
                    "shunt-resistor") == "10000"
    assert_base_untouched(sbx, r)
    assert r.env["bootcount"] == "1"
    assert r.env["boot_part"] == "a"
    wdt = r.output.find("OE5XRX_T_WDT start 15000")
    s2 = r.output.find("=== OE5XRX boot stage 2")
    assert 0 <= wdt < s2, r.output


def test_two_overlays_both_applied(sbx, dtbos, tmp_path):
    r = boot(sbx, tmp_path, standard_slots(sbx, dtbos, [INA, MARKER]))
    assert_booted(r, "a")
    assert marker(r.bootargs, "oe5xrx.overlays") == [f"ok:{INA},{MARKER}"]
    assert prop(r.fdt_path, f"{I2C1}/ina226@40", "shunt-resistor") == "10000"
    assert prop(r.fdt_path, "/", "oe5xrx,test-marker") == "slot-overlay"
    assert_base_untouched(sbx, r)


def test_empty_overlay_list_has_no_overlays_marker(sbx, dtbos, tmp_path):
    r = boot(sbx, tmp_path, standard_slots(sbx, dtbos, []))
    assert_booted(r, "a")
    assert marker(r.bootargs, "oe5xrx.stage2") == ["ok"]
    assert "oe5xrx.overlays" not in r.bootargs
    assert r.booti_fdt_addr == FDT_ADDR_R
    assert_no_overlay_applied(r)


def test_stage2_missing_falls_back(sbx, dtbos, tmp_path):
    slots = {s: slot_files(sbx, s, stage2=None, overlays={INA: dtbos[INA]})
             for s in ("a", "b")}
    r = boot(sbx, tmp_path, slots)
    assert_booted(r, "a")
    assert marker(r.bootargs, "oe5xrx.stage2") == ["missing"]
    assert "oe5xrx.overlays" not in r.bootargs
    assert r.booti_fdt_addr == FDT_ADDR  # firmware DTB, like before stage 2
    assert_no_overlay_applied(r)
    assert r.env["bootcount"] == "1"


def test_stage2_returning_falls_back_failed(sbx, tmp_path):
    s2 = script_bytes("echo broken\n", sbx["mkimage"])
    slots = {s: slot_files(sbx, s, stage2=s2) for s in ("a", "b")}
    r = boot(sbx, tmp_path, slots)
    assert_booted(r, "a")
    assert "broken" in r.output
    assert marker(r.bootargs, "oe5xrx.stage2") == ["failed"]
    assert "oe5xrx.overlays" not in r.bootargs
    assert r.booti_fdt_addr == FDT_ADDR


def test_broken_overlay_boots_without_overlays(sbx, dtbos, tmp_path):
    # Review Focus 2: the first overlay applies, the second fails -> no
    # half-patched tree, boot without ANY overlay.
    r = boot(sbx, tmp_path, standard_slots(sbx, dtbos, [INA, BROKEN]))
    assert_booted(r, "a")
    assert marker(r.bootargs, "oe5xrx.stage2") == ["ok"]
    assert marker(r.bootargs, "oe5xrx.overlays") == [f"failed:{BROKEN}"]
    assert "FDT_ERR_NOTFOUND" in r.output  # the apply really failed
    assert r.booti_fdt_addr == FDT_ADDR_R
    assert_no_overlay_applied(r)
    assert_base_untouched(sbx, r)


def test_missing_overlay_file_marks_failed(sbx, dtbos, tmp_path):
    # Review Focus 4: listed but not shipped in the slot.
    missing = "oe5xrx-not-shipped"
    r = boot(sbx, tmp_path,
             standard_slots(sbx, dtbos, [INA, missing], shipped=[INA]))
    assert_booted(r, "a")
    assert marker(r.bootargs, "oe5xrx.stage2") == ["ok"]
    assert marker(r.bootargs, "oe5xrx.overlays") == [f"failed:{missing}"]
    assert_no_overlay_applied(r)
    assert_base_untouched(sbx, r)


def test_trial_rollback_a_to_b_honours_custom_bootlimit(sbx, dtbos,
                                                        tmp_path):
    # Mirror of the agent-gate case: trial on slot A (rollback target B) with
    # a non-default bootlimit=2 — the limit is read from the env, not
    # hard-coded, and the rollback works in both directions.
    env = {"boot_part": "a", "upgrade_available": "1", "bootcount": "2",
           "bootlimit": "2"}
    r = boot(sbx, tmp_path, standard_slots(sbx, dtbos, [INA]), env)
    assert_booted(r, "b")
    assert "rolling back" in r.output
    assert r.env == {"boot_part": "b", "bootcount": "1",
                     "upgrade_available": "0", "bootlimit": "2"}


def test_agent_gate_rollback_bootcount_at_limit(sbx, dtbos, tmp_path):
    # Agent commit gate (spec §5): a trial boot (slot b) whose boot gate fails
    # (oe5xrx.stage2 != ok or oe5xrx.overlays=failed:...) makes the agent set
    # bootcount=<bootlimit> (upgrade_available stays 1), report rolled_back
    # and reboot ONCE. Stage 1's existing rollback branch (increment, then
    # bootcount -gt bootlimit) must switch the slot on exactly that boot.
    slots = standard_slots(sbx, dtbos, [INA])
    env = {"boot_part": "b", "upgrade_available": "1", "bootcount": "3",
           "bootlimit": "3"}
    r = boot(sbx, tmp_path, slots, env)
    assert_booted(r, "a")
    assert "rolling back" in r.output
    assert marker(r.bootargs, "oe5xrx.stage2") == ["ok"]
    assert {k: r.env[k] for k in ("boot_part", "upgrade_available",
                                  "bootcount")} == {
        "boot_part": "a", "upgrade_available": "0", "bootcount": "1"}
    # Boundary: one below the limit must NOT roll back (the agent has to
    # write exactly bootlimit, not bootlimit-1).
    env_below = dict(env, bootcount="2")
    r2 = boot(sbx, tmp_path, slots, env_below, name="below")
    assert_booted(r2, "b")
    assert "rolling back" not in r2.output
    assert r2.env["boot_part"] == "b" and r2.env["bootcount"] == "3"
    assert r2.env["upgrade_available"] == "1"


def test_trial_without_commit_rolls_back_after_bootlimit(sbx, dtbos,
                                                         tmp_path):
    # Review Focus 5: an OTA trial (slot b) that never commits.
    slots = standard_slots(sbx, dtbos, [INA])
    env = {"boot_part": "b", "upgrade_available": "1", "bootcount": "0"}
    seen = []
    for n in range(1, 5):
        r = boot(sbx, tmp_path, slots, env, name=f"boot{n}")
        assert r.booted, r.output
        seen.append(r.bootargs.split()[0])
        env = r.env
        if n <= 3:
            assert_booted(r, "b")
            assert env == {"boot_part": "b", "bootcount": str(n),
                           "upgrade_available": "1", "bootlimit": "3"}
    assert seen == ["root=PARTLABEL=root_b"] * 3 + ["root=PARTLABEL=root_a"]
    assert_booted(r, "a")
    assert env == {"boot_part": "a", "bootcount": "1",
                   "upgrade_available": "0", "bootlimit": "3"}


def test_stage2_clobbering_vars_does_not_break_fallback(sbx, tmp_path):
    # Review Focus 1: a broken OTA'd stage 2 bends stage 1's inputs, returns.
    s2 = script_bytes(
        "setenv fdt_addr 0\n"
        "setenv kernel_addr_r 0x5000000\n"
        "setenv root_partnum 99\n"
        "setenv boot_part z\n", sbx["mkimage"])
    slots = {s: slot_files(sbx, s, stage2=s2) for s in ("a", "b")}
    r = boot(sbx, tmp_path, slots)
    assert_booted(r, "a")
    assert r.booti_fdt_addr == FDT_ADDR
    assert marker(r.bootargs, "oe5xrx.stage2") == ["failed"]
    assert_base_untouched(sbx, r)
    assert r.env["boot_part"] == "a"


def test_stage2_clobbering_device_and_marker_is_repinned(sbx, tmp_path):
    # A returning stage 2 must neither redirect the fallback's boot device
    # nor make the fallback look like a good stage-2 boot (the agent would
    # commit it).
    s2 = script_bytes(
        "setenv oe5xrx_devtype bogus\n"
        "setenv oe5xrx_devnum 9\n"
        "setenv oe5xrx_stage2 ok\n", sbx["mkimage"])
    slots = {s: slot_files(sbx, s, stage2=s2) for s in ("a", "b")}
    r = boot(sbx, tmp_path, slots)
    assert_booted(r, "a")
    assert marker(r.bootargs, "oe5xrx.stage2") == ["failed"]
    assert "rootfs host 0:" in r.output


def test_stale_env_vars_are_overridden(sbx, dtbos, tmp_path):
    # Review Focus 3: foreign values persisted in the env.
    env = {"oe5xrx_devtype": "bogus", "oe5xrx_devnum": "7",
           "oe5xrx_stage2": "ok"}
    r = boot(sbx, tmp_path, standard_slots(sbx, dtbos, [INA]), env)
    assert_booted(r, "a")
    assert marker(r.bootargs, "oe5xrx.stage2") == ["ok"]
    assert marker(r.bootargs, "oe5xrx.overlays") == [f"ok:{INA}"]
    assert "bogus" not in r.output


def test_stale_stage2_marker_not_inherited_by_fallback(sbx, tmp_path):
    env = {"oe5xrx_stage2": "ok"}
    slots = {s: slot_files(sbx, s, stage2=None) for s in ("a", "b")}
    r = boot(sbx, tmp_path, slots, env)
    assert_booted(r, "a")
    assert marker(r.bootargs, "oe5xrx.stage2") == ["missing"]


def test_missing_slot_partition_resets(sbx, dtbos, tmp_path):
    r = boot(sbx, tmp_path, standard_slots(sbx, dtbos, [INA]),
             {"boot_part": "c"})
    assert r.reset, r.output
    assert not r.booted
    assert "root_c partition not found" in r.output
    assert r.env["bootcount"] == "1"  # counted before the reset


# --- stage-1 rescue paths: booti returning (BootiReject) ----------------------

def test_stage2_booti_returning_falls_back_failed(sbx, dtbos, tmp_path):
    # (a) The real stage 2 reaches booti, booti returns -> stage 1's frozen
    # fallback boots the firmware DTB, tagged oe5xrx.stage2=failed.
    r = boot(sbx, tmp_path, standard_slots(sbx, dtbos, [INA]),
             reject_booti=BootiReject(first=1))
    assert r.rejected_booti == [(KERNEL_ADDR_R, FDT_ADDR_R)], r.output
    assert "Stage 2 could not boot" in r.output
    assert "Stage 2 returned without booting" in r.output
    assert_booted(r, "a")
    assert r.booti_fdt_addr == FDT_ADDR
    assert marker(r.bootargs, "oe5xrx.stage2") == ["failed"]
    assert "oe5xrx.overlays" not in r.bootargs
    assert_no_overlay_applied(r)
    assert_base_untouched(sbx, r)


@pytest.mark.parametrize("shipped,want", [
    # both present: the broadcom/ path is tried first and wins
    ({ROOTFS_DTB_BROADCOM: "broadcom", ROOTFS_DTB_PLAIN: "plain"},
     "broadcom"),
    # only the plain path: tried second
    ({ROOTFS_DTB_PLAIN: "plain"}, "plain"),
])
def test_firmware_dtb_rejected_boots_rootfs_dtb(sbx, tmp_path, shipped,
                                                 want):
    # (b) No stage 2; the fallback's firmware-DTB booti returns -> the
    # rootfs DTB is loaded to ${fdt_addr_r} and booted.
    slots = {}
    for s_ in ("a", "b"):
        files = slot_files(sbx, s_, stage2=None)
        files.update({p: rootfs_dtb(t) for p, t in shipped.items()})
        slots[s_] = files
    r = boot(sbx, tmp_path, slots, reject_booti=BootiReject(fdt=(FDT_ADDR,)))
    assert r.rejected_booti == [(KERNEL_ADDR_R, FDT_ADDR)], r.output
    assert "falling back to rootfs DTB" in r.output
    assert_booted(r, "a")
    assert r.booti_fdt_addr == FDT_ADDR_R
    assert r.fdt_path.read_bytes() == rootfs_dtb(want)
    assert marker(r.bootargs, "oe5xrx.stage2") == ["missing"]
    assert_base_untouched(sbx, r)


def test_no_firmware_dtb_skips_stage2_boots_rootfs_dtb(sbx, dtbos, tmp_path):
    # (c) ${fdt_addr} unset (firmware passed no DTB): stage 2 must not boot
    # (its copy chain is gated on fdt_addr); the fallback skips the
    # firmware-DTB booti and boots the rootfs DTB.
    slots = standard_slots(sbx, dtbos, [INA])
    for files in slots.values():
        files[ROOTFS_DTB_BROADCOM] = rootfs_dtb("broadcom")
    r = boot(sbx, tmp_path, slots, fdt_addr=None)
    assert "Running stage 2" in r.output
    assert "Stage 2 could not boot" in r.output
    assert "Booting with firmware DTB" not in r.output
    assert r.rejected_booti == []
    assert_booted(r, "a")
    assert r.output.count("OE5XRX_T_BOOTI kernel=") == 1
    assert r.booti_fdt_addr == FDT_ADDR_R
    assert r.fdt_path.read_bytes() == rootfs_dtb("broadcom")
    assert marker(r.bootargs, "oe5xrx.stage2") == ["failed"]
    assert "oe5xrx.overlays" not in r.bootargs


def test_kernel_missing_resets(sbx, dtbos, tmp_path):
    # (d) No /boot/Image in the slot: neither stage 2 nor the fallback can
    # boot -> reset (bootcount already counted).
    slots = standard_slots(sbx, dtbos, [INA])
    for files in slots.values():
        del files["/boot/Image"]
    r = boot(sbx, tmp_path, slots)
    assert r.reset, r.output
    assert not r.booted
    assert "OE5XRX_T_BOOTI" not in r.output
    assert "Stage 2 could not boot" in r.output
    assert "Kernel/dtb load failed" in r.output
    assert r.env["bootcount"] == "1"


def test_all_booti_rejected_resets_and_counts(sbx, dtbos, tmp_path):
    # (e) Every booti returns (stage 2 copy, firmware DTB, rootfs DTB) ->
    # reset; the bootcount increment was persisted before, so repeated
    # failures progress towards the rollback.
    slots = standard_slots(sbx, dtbos, [INA])
    for files in slots.values():
        files[ROOTFS_DTB_BROADCOM] = rootfs_dtb("broadcom")
    env = {"boot_part": "b", "upgrade_available": "1", "bootcount": "1",
           "bootlimit": "3"}
    r = boot(sbx, tmp_path, slots, env, reject_booti=BootiReject(all=True))
    assert r.rejected_booti == [(KERNEL_ADDR_R, FDT_ADDR_R),
                                (KERNEL_ADDR_R, FDT_ADDR),
                                (KERNEL_ADDR_R, FDT_ADDR_R)], r.output
    assert r.reset, r.output
    assert not r.booted
    assert "Kernel/dtb load failed" in r.output
    assert r.env == {"boot_part": "b", "bootcount": "2",
                     "upgrade_available": "1", "bootlimit": "3"}


_RE_ECHO = re.compile(
    r"""\becho\b(?:[ \t]+(?:"[^"]*"|'[^']*'|[^\s;|&"']+))*""")
_HW_CMDS = ("booti", "saveenv", "reset", "wdt", "mmc")


def _code(script: str) -> str:
    """Non-comment lines with `echo` commands (and their arguments) removed.

    Other quoted strings are KEPT: a command hidden in e.g.
    `setenv x 'booti ...'; run x` must still count as a residual command."""
    lines = [ln for ln in script.splitlines()
             if not ln.lstrip().startswith("#")]
    return _RE_ECHO.sub("echo", "\n".join(lines))


def _residual(code: str) -> list[str]:
    return [c for c in _HW_CMDS if re.search(rf"\b{c}\b", code)]


def test_residual_guard_sees_quoted_commands():
    assert _residual(_code("setenv x 'booti 1 - 2'; run x\n")) == ["booti"]
    assert _residual(_code('setenv y "mmc dev 0"\n')) == ["mmc"]
    assert _residual(_code('echo "  reset via wdt"; echo \'saveenv\'\n'
                           "echo booti mmc || echo 'x'\n")) == []


def test_rewrite_hits_every_indirection():
    stage1 = read_stage1()
    stage2 = render_stage2(read_stage2_template(), [INA, MARKER])
    for text, is_s1 in ((stage1, True), (stage2, False)):
        before = _code(text)
        after = _code(rewrite_for_sandbox(text, stage1=is_s1))
        assert re.search(r"\bbooti\b", before)
        assert _residual(after) == [], is_s1
        assert after.count("run oe5xrx_t_booti") == len(
            re.findall(r"\bbooti\b", before))
    s1 = "\n".join(ln for ln in rewrite_for_sandbox(stage1, stage1=True)
                   .splitlines() if not ln.lstrip().startswith("#"))
    assert s1.count("echo OE5XRX_T_WDT ") == 2
    assert s1.count("setenv oe5xrx_devtype host") == 2
    assert "run oe5xrx_t_saveenv" in s1 and "run oe5xrx_t_reset" in s1
    # A script whose command escapes the rules must not pass silently.
    with pytest.raises(AssertionError):
        rewrite_for_sandbox("echo no boot here\n", stage1=False)
