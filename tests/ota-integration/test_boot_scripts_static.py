"""Static text rules for the two-stage CM4 U-Boot boot (spec
docs/superpowers/specs/2026-11-04-slot-boot-stage2-overlays-design.md):

- Stage 1 (boot.cmd -> FAT boot.scr) is FROZEN: env defaults, bootcount,
  watchdog and rollback stay verbatim; stage 2 is sourced only after all of
  that; the fallback boots exactly like before with a frozen bootargs copy.
- Stage 2 (boot-stage2.cmd.in -> slot /boot/boot-stage2.scr) never touches the
  rollback state and only ever patches a COPY of the firmware DTB.

Pure file-content checks (plus mkimage when installed) — run on every PR via
`-m unit`. Behaviour is exercised in the U-Boot sandbox tests."""

import os
import re
import shutil
import subprocess

import pytest
from boot_scripts import (
    PH_OVERLAYS,
    PH_OVERLAYS_BOOTARG,
    PH_OVERLAYS_CSV,
    read_stage1,
    read_stage2_template,
    render_stage2,
)

pytestmark = pytest.mark.unit

# Copied verbatim from boot.cmd on main before the stage-2 change. Stage 1's
# fallback must keep booting with exactly these bootargs (frozen copy, §2.6).
FROZEN_BOOTARGS = (
    "root=PARTLABEL=root_${boot_part} ro rootwait fsck.repair=yes "
    "net.ifnames=0 panic=5 softlockup_panic=1 reserve_mem=2M:4096:oops "
    "ramoops.mem_name=oops ramoops.ecc=1 ramoops.record_size=0x40000 "
    "ramoops.console_size=0x40000 ramoops.pmsg_size=0x40000 "
    "console=tty1 console=serial0,115200"
)

# Verbatim blocks from boot.cmd on main that must survive unchanged.
DEFAULTS_BLOCK = """\
if test -z "${boot_part}"; then setenv boot_part a; fi
if test -z "${bootcount}"; then setenv bootcount 0; fi
if test -z "${upgrade_available}"; then setenv upgrade_available 0; fi
if test -z "${bootlimit}"; then setenv bootlimit 3; fi
"""
INCREMENT_BLOCK = """\
setexpr bootcount ${bootcount} + 1
saveenv
"""
ROLLBACK_BLOCK = """\
if test ${upgrade_available} -gt 0 && test ${bootcount} -gt ${bootlimit}; then
    echo "  Trial boot failed ${bootlimit} times — rolling back."
    if test "${boot_part}" = "a"; then
        setenv boot_part b
    else
        setenv boot_part a
    fi
    setenv bootcount 1
    setenv upgrade_available 0
    saveenv
    echo "  Retrying from slot ${boot_part}"
fi
"""

SOURCE_LINE = "source ${scriptaddr}"
DEVICE_LINES = ("setenv oe5xrx_devtype mmc", "setenv oe5xrx_devnum 0")
SAVED_VARS = ("fdt_addr", "kernel_addr_r", "fdt_addr_r", "root_partnum",
              "boot_part")


def _code_lines(txt):
    """Stripped non-comment, non-blank lines (hush comments start with #)."""
    return [ln.strip() for ln in txt.splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")]


def _depths(lines):
    """Nesting depth (if/for) at which each code line starts."""
    depth, out = 0, []
    for ln in lines:
        out.append(depth)
        toks = re.split(r"[\s;]+", ln)
        depth += toks.count("if") + toks.count("for")
        depth -= toks.count("fi") + toks.count("done")
    assert depth == 0
    return out


def _commands(ln):
    """Split a code line into its commands: drops a leading `if `/`else`
    and a trailing `; then`/`; do`, splits on `&&` and `;`."""
    ln = re.sub(r"^(if|elif)\s+", "", ln)
    ln = re.sub(r";\s*(then|do)$", "", ln)
    return [c.strip() for c in re.split(r"&&|;", ln) if c.strip()]


def _index(lines, line):
    assert line in lines, f"missing line: {line!r}"
    return lines.index(line)


def _stage2(overlays=("oe5xrx-ina226",)):
    return render_stage2(read_stage2_template(), list(overlays))


# ---- stage 1 ------------------------------------------------------------

def test_stage1_has_frozen_header():
    assert "STAGE 1 — FROZEN after this change, only changeable by reflash; " \
           "keep minimal." in read_stage1()


def test_stage1_keeps_rollback_block_verbatim():
    s1 = read_stage1()
    src = s1.index(SOURCE_LINE)
    pos = []
    for block in (DEFAULTS_BLOCK, INCREMENT_BLOCK, ROLLBACK_BLOCK):
        assert block in s1, f"block changed/missing:\n{block}"
        pos.append(s1.index(block))
    assert pos == sorted(pos)
    assert pos[-1] < src
    # The bootcount persist is the first saveenv in the code.
    lines = _code_lines(s1)
    first_save = lines.index("saveenv")
    assert lines[first_save - 1] == "setexpr bootcount ${bootcount} + 1"


def test_stage1_arms_watchdog_before_source():
    lines = _code_lines(read_stage1())
    src = _index(lines, SOURCE_LINE)
    wdt = [i for i, ln in enumerate(lines) if ln.startswith("wdt start 15000")]
    assert wdt and wdt[0] < src
    assert any(ln.startswith("wdt dev ") for ln in lines[:wdt[0]])


def test_stage1_loads_and_sources_stage2():
    lines = _code_lines(read_stage1())
    load = _index(lines, "if ext4load ${oe5xrx_devtype} ${oe5xrx_devnum}:"
                  "${root_partnum} ${scriptaddr} /boot/boot-stage2.scr; then")
    missing = _index(lines, "setenv oe5xrx_stage2 missing")
    failed = _index(lines, "setenv oe5xrx_stage2 failed")
    src = _index(lines, SOURCE_LINE)
    assert missing < load < failed < src
    assert lines.count(SOURCE_LINE) == 1


def test_stage1_fallback_bootargs_frozen_copy():
    lines = _code_lines(read_stage1())
    want = f'setenv bootargs "{FROZEN_BOOTARGS} oe5xrx.stage2=${{oe5xrx_stage2}}"'
    bootargs = [ln for ln in lines if ln.startswith("setenv bootargs")]
    assert bootargs == [want]
    assert lines.index(want) > lines.index(SOURCE_LINE)


def test_stage1_sets_device_unconditionally():
    lines = _code_lines(read_stage1())
    depths = _depths(lines)
    src = _index(lines, SOURCE_LINE)
    last_restore = _index(lines, "setenv boot_part ${oe5xrx_s1_boot_part}")
    # Any write to the boot-device vars must be exactly one of the literal
    # lines (the sandbox harness rewrites them textually), at depth 0.
    for i, ln in enumerate(lines):
        if re.search(r"\b(setenv|setexpr|env set)\s+oe5xrx_dev(type|num)\b", ln):
            assert ln in DEVICE_LINES, f"unexpected device write: {ln!r}"
            assert depths[i] == 0, f"{ln!r} is inside an if/for"
    uses = [i for i, ln in enumerate(lines) if "${oe5xrx_devtype}" in ln]
    last_save = max(i for i, ln in enumerate(lines) if "saveenv" in ln)
    for want in DEVICE_LINES:
        idx = [i for i, ln in enumerate(lines) if ln == want]
        # Before stage 2: after the last saveenv (never persisted) and
        # before the first use.
        assert any(last_save < i < uses[0] for i in idx), want
        # After stage 2 returned: re-pinned after the restore block and
        # before the fallback's first use, so a stage 2 that sets/clears
        # them can never redirect the frozen fallback.
        after = [u for u in uses if u > src]
        assert after, "fallback does not use ${oe5xrx_devtype}"
        assert any(last_restore < i < after[0] for i in idx), \
            f"{want!r} not re-pinned after stage 2"
    # No hardcoded boot device left in the code.
    assert not any("mmc 0" in ln for ln in lines)


def test_stage1_repins_stage2_marker_after_source():
    lines = _code_lines(read_stage1())
    src = _index(lines, SOURCE_LINE)
    assert lines[src + 1] == "setenv oe5xrx_stage2 failed"


def test_stage1_saves_and_restores_vars_around_source():
    lines = _code_lines(read_stage1())
    src = _index(lines, SOURCE_LINE)
    for v in SAVED_VARS:
        save = _index(lines, f"setenv oe5xrx_s1_{v} ${{{v}}}")
        restore = _index(lines, f"setenv {v} ${{oe5xrx_s1_{v}}}")
        assert save < src < restore, v


# ---- stage 2 ------------------------------------------------------------

_FORBIDDEN_STAGE2 = [
    r"\bsaveenv\b",
    r"\benv\s+(save|set|import|default|delete)\b",
    (r"\b(setenv|setexpr|editenv|askenv)\s+"
     r"(bootcount|upgrade_available|boot_part|bootlimit|oe5xrx_stage2"
     r"|oe5xrx_devtype|oe5xrx_devnum|oe5xrx_s1_\w*)\b"),
]


@pytest.mark.parametrize("overlays", [("oe5xrx-ina226",), ()])
def test_stage2_never_touches_rollback_state(overlays):
    for ln in _code_lines(_stage2(overlays)):
        for pat in _FORBIDDEN_STAGE2:
            assert not re.search(pat, ln), f"stage 2 must not: {ln!r}"


COPY_CHAIN = ('if test -n "${fdt_addr}" && fdt addr ${fdt_addr} && '
              'fdt move ${fdt_addr} ${fdt_addr_r} && fdt addr ${fdt_addr_r} && '
              'fdt resize 0x10000; then')
BOOTI_S2 = "booti ${kernel_addr_r} - ${fdt_addr_r}"
FDT_OK_GATE = 'if test "${oe5xrx_fdt_ok}" = 1; then'


def test_stage2_works_on_copy():
    lines = _code_lines(_stage2())
    current = None          # working fdt per `fdt addr` / `fdt move`
    copied = False
    applies = 0
    for cmd in (c for ln in lines for c in _commands(ln)):
        m = re.match(r"fdt addr (\S+)$", cmd)
        if m:
            current = m.group(1)
            continue
        m = re.match(r"fdt move (\S+) (\S+)", cmd)
        if m:
            assert m.groups() == ("${fdt_addr}", "${fdt_addr_r}"), cmd
            current, copied = "${fdt_addr_r}", True
            continue
        if re.match(r"fdt (apply|resize|set|rm|mknode|chosen)\b", cmd):
            assert copied, f"tree modified before copying: {cmd!r}"
            assert current == "${fdt_addr_r}", \
                f"modifies {current} instead of the copy: {cmd!r}"
            applies += cmd.startswith("fdt apply")
    assert applies >= 1
    booti = [ln for ln in lines if re.match(r"booti\b", ln)]
    assert booti == [BOOTI_S2]


def test_stage2_copy_steps_are_gated():
    """Every fdt copy step is part of the && chain of COPY_CHAIN: no bare
    (unchecked) `fdt addr|move|resize` line exists."""
    lines = _code_lines(_stage2())
    for ln in lines:
        if ln != COPY_CHAIN:
            assert not re.match(r"fdt (addr|move|resize|header)\b", ln), \
                f"unchecked fdt copy step: {ln!r}"
    assert lines.count(COPY_CHAIN) == 2      # first copy + re-copy


def test_stage2_booti_only_after_complete_copy():
    lines = _code_lines(_stage2())
    depths = _depths(lines)
    booti = _index(lines, BOOTI_S2)
    gate = _index(lines, FDT_OK_GATE)
    # booti sits directly inside the oe5xrx_fdt_ok=1 branch (no else/elif
    # in between, branch not closed before it).
    assert gate < booti and depths[booti] == depths[gate] + 1
    assert all(depths[i] > depths[gate] and lines[i] != "else"
               and not lines[i].startswith("elif")
               for i in range(gate + 1, booti + 1))
    # The flag is cleared at stage-2 start (stale env) and before the
    # re-copy, and set to 1 ONLY as the first statement of a COPY_CHAIN
    # success branch.
    sets = [i for i, ln in enumerate(lines)
            if re.match(r"setenv oe5xrx_fdt_ok\b", ln)]
    for i in sets:
        if lines[i] == "setenv oe5xrx_fdt_ok 1":
            assert lines[i - 1] == COPY_CHAIN, i
            assert depths[i] == depths[i - 1] + 1
        else:
            assert lines[i] == "setenv oe5xrx_fdt_ok", lines[i]
            assert lines[i + 1] == COPY_CHAIN, i
    assert lines[sets[0]] == "setenv oe5xrx_fdt_ok" and sets[0] < gate
    assert sum(lines[i] == "setenv oe5xrx_fdt_ok 1" for i in sets) == 2


def test_stage2_discards_copy_on_overlay_failure():
    lines = _code_lines(_stage2())
    fail = _index(lines, 'if test -n "${oe5xrx_ovl_failed}"; then')
    booti = _index(lines, BOOTI_S2)
    recopy = [i for i, ln in enumerate(lines) if ln == COPY_CHAIN]
    assert any(fail < i < booti for i in recopy)
    assert any(ln.startswith('setenv oe5xrx_ovl_bootarg " oe5xrx.overlays='
                             'failed:${oe5xrx_ovl_failed}"')
               for ln in lines[fail:booti])


def test_stage2_bootargs_carry_markers():
    bootargs = [ln for ln in _code_lines(_stage2())
                if ln.startswith("setenv bootargs")]
    assert len(bootargs) == 1
    assert bootargs[0].endswith(' oe5xrx.stage2=ok${oe5xrx_ovl_bootarg}"')
    assert "root=PARTLABEL=root_${boot_part} " in bootargs[0]


def test_release_scripts_call_booti_wdt_directly():
    s1 = _code_lines(read_stage1())
    s2 = _code_lines(_stage2())
    for lines in (s1, s2):
        assert not any("oe5xrx_t_" in ln for ln in lines)
        assert not any(re.match(r"run\b", ln) for ln in lines)
        assert any(ln.startswith("booti ${kernel_addr_r} - ") for ln in lines)
    assert any(ln.startswith("wdt dev watchdog@7e100000") for ln in s1)
    assert any(ln.startswith("wdt start 15000") for ln in s1)
    assert "reset" in s1
    assert "saveenv" in s1


# ---- render_stage2 -------------------------------------------------------

def test_render_stage2_substitutes_and_rejects_bad_names():
    tpl = read_stage2_template()
    for ph in (PH_OVERLAYS, PH_OVERLAYS_CSV, PH_OVERLAYS_BOOTARG):
        assert ph in tpl, ph

    out = render_stage2(tpl, ["oe5xrx-ina226", "oe5xrx-foo2"])
    assert "@OE5XRX_" not in out
    assert "for o in oe5xrx-ina226 oe5xrx-foo2; do" in _code_lines(out)
    assert 'setenv oe5xrx_ovl_bootarg " oe5xrx.overlays=ok:' \
           'oe5xrx-ina226,oe5xrx-foo2"' in _code_lines(out)

    for bad in ("Foo", "a b", "a;reset", "", "a_b", "../x", "a$b", 'a"'):
        with pytest.raises(ValueError):
            render_stage2(tpl, ["oe5xrx-ina226", bad])

    # Empty list: still a valid script (hush accepts an empty for-list —
    # verified in the U-Boot sandbox) and no ok-marker; the failure marker
    # is unreachable because the loop body never runs.
    empty = render_stage2(tpl, [])
    assert "@OE5XRX_" not in empty
    assert not any("oe5xrx.overlays=ok" in ln for ln in _code_lines(empty))
    assert "for o in ; do" in _code_lines(empty)
    assert 'setenv oe5xrx_ovl_bootarg ""' in _code_lines(empty)


# ---- mkimage --------------------------------------------------------------

def test_scripts_build_with_mkimage(tmp_path):
    mkimage = shutil.which("mkimage")
    if not mkimage:
        if os.environ.get("CI"):
            pytest.fail("mkimage not installed in CI (u-boot-tools)")
        pytest.skip("mkimage not installed")
    sources = {
        "boot.cmd": read_stage1(),
        "stage2-ina226.cmd": _stage2(("oe5xrx-ina226",)),
        "stage2-empty.cmd": _stage2(()),
    }
    for name, text in sources.items():
        src = tmp_path / name
        src.write_text(text)
        out = tmp_path / (name + ".scr")
        r = subprocess.run(
            [mkimage, "-A", "arm64", "-O", "linux", "-T", "script",
             "-C", "none", "-a", "0", "-e", "0", "-n", name,
             "-d", str(src), str(out)],
            capture_output=True, text=True, check=False)
        assert r.returncode == 0, r.stdout + r.stderr
        assert out.stat().st_size > len(text.encode())
