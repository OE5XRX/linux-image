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


def boot(sbx, tmp_path: Path, slots, env=None, name="boot"):
    disk = tmp_path / "disk.img"
    if not disk.exists():
        make_test_disk(disk, slots)
    return run_boot(tmp_path / name, disk, read_stage1(), sbx["dtb"],
                    env or {}, uboot=sbx["uboot"], mkimage=sbx["mkimage"])


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


def test_trial_rollback_when_bootcount_exceeds_limit(sbx, dtbos, tmp_path):
    env = {"boot_part": "b", "upgrade_available": "1", "bootcount": "3",
           "bootlimit": "3"}
    r = boot(sbx, tmp_path, standard_slots(sbx, dtbos, [INA]), env)
    assert_booted(r, "a")
    assert "rolling back" in r.output
    assert r.env == {"boot_part": "a", "bootcount": "1",
                     "upgrade_available": "0", "bootlimit": "3"}


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


def _code(script: str) -> str:
    """Non-comment lines with quoted strings removed."""
    lines = [ln for ln in script.splitlines()
             if not ln.lstrip().startswith("#")]
    return re.sub(r"\"[^\"]*\"|'[^']*'", '""', "\n".join(lines))


def test_rewrite_hits_every_indirection():
    stage1 = read_stage1()
    stage2 = render_stage2(read_stage2_template(), [INA, MARKER])
    for text, is_s1 in ((stage1, True), (stage2, False)):
        before = _code(text)
        after = _code(rewrite_for_sandbox(text, stage1=is_s1))
        assert re.search(r"\bbooti\b", before)
        for cmd in ("booti", "saveenv", "reset", "wdt", "mmc"):
            assert not re.search(rf"\b{cmd}\b", after), (cmd, is_s1)
        assert after.count("run oe5xrx_t_booti") == len(
            re.findall(r"\bbooti\b", before))
    s1 = _code(rewrite_for_sandbox(stage1, stage1=True))
    assert s1.count("echo OE5XRX_T_WDT ") == 2
    assert s1.count("setenv oe5xrx_devtype host") == 2
    assert "run oe5xrx_t_saveenv" in s1 and "run oe5xrx_t_reset" in s1
    # A script whose command escapes the rules must not pass silently.
    with pytest.raises(AssertionError):
        rewrite_for_sandbox("echo no boot here\n", stage1=False)
