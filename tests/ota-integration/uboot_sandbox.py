"""U-Boot sandbox harness for the two-stage CM4 boot scripts.

Runs the REAL stage-1 (`boot.cmd`) and stage-2 (`boot-stage2.cmd.in`, rendered
with `boot_scripts.render_stage2`) texts in a U-Boot v2026.01 sandbox (same
hush + fdt/ext4/part commands as the rpi image). Only the hardware-facing
commands are rewritten textually (`rewrite_for_sandbox`):

  booti A - B           -> setenv oe5xrx_t_kernel A; setenv oe5xrx_t_fdt B;
                           run oe5xrx_t_booti      (dump state + poweroff,
                           or return like a failed booti: BootiReject)
  wdt ... (line start)  -> echo OE5XRX_T_WDT ...
  reset                 -> run oe5xrx_t_reset      (marker + poweroff)
  saveenv               -> run oe5xrx_t_saveenv    (env export -> env.txt)
  stage 1 only: setenv oe5xrx_devtype mmc -> setenv oe5xrx_devtype host

The boot medium is a GPT disk image (`make_test_disk`) bound as `host 0`, with
the wks partition order firmware/uboot_env/uboot_envr/root_a/root_b (1..5).
One sandbox process = one simulated boot; the persisted env (the four rollback
variables written by `saveenv`) is carried between boots via env.txt.

Environment:
  UBOOT_SANDBOX  build dir with `u-boot` + `tools/mkimage`
                 (scripts/build-uboot-sandbox.sh <dir>)
  CM4_BASE_DTB   real CM4 firmware DTB (raspberrypi/firmware pin, see ci.yml)
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

# Load addresses = U-Boot v2026.01 rpi defaults (board/raspberrypi/rpi/
# rpi.env). fdt_addr is set by the GPU firmware on the CM4; in the sandbox
# (256 MiB RAM, U-Boot's own malloc area ~0x9c11000..0xfc11000 lmb-reserved)
# the firmware-DTB stand-in sits below that.
KERNEL_ADDR_R = "0x00080000"
SCRIPTADDR = "0x05400000"
FDT_ADDR_R = "0x05600000"
RAMDISK_ADDR_R = "0x05700000"
FDT_ADDR = "0x08000000"
# Harness-private buffers (not visible to the scripts under test), clear of
# the script-visible areas above and of 0x5000000 (a test injects
# kernel_addr_r=0x5000000 to prove stage 1 re-pins its addresses).
_PRELUDE_ADDR = "0x06000000"
_STAGE1_ADDR = "0x06800000"
_ENV_ADDR = "0x07000000"

# Only these survive a simulated reboot (saveenv): they are the complete
# state boot.cmd reads/writes across boots; everything else (addresses,
# oe5xrx_* scratch vars) is re-set by the prelude or the scripts every boot.
PERSISTED_VARS = ("boot_part", "bootcount", "upgrade_available", "bootlimit")
BOOT_TIMEOUT_S = 30

_MIB = 1024 * 1024
_SECTOR = 512
# (label, size MiB) in wks order -> partition numbers 1..5.
_PARTITIONS = (
    ("firmware", 4),
    ("uboot_env", 1),
    ("uboot_envr", 1),
    ("root_a", 16),
    ("root_b", 16),
)


class SandboxUnavailable(RuntimeError):
    pass


def env_path(name: str) -> Path | None:
    """Absolute path from environment variable `name` (None if unset/empty).
    Resolved against the CWD at call time: run_boot executes the sandbox
    with cwd=<workdir>, where a relative path would point elsewhere."""
    v = os.environ.get(name)
    return Path(v).resolve() if v else None


def sandbox_paths() -> tuple[Path, Path, Path]:
    """(u-boot, mkimage, base_dtb) from UBOOT_SANDBOX / CM4_BASE_DTB,
    absolute."""
    ub = env_path("UBOOT_SANDBOX")
    dtb = env_path("CM4_BASE_DTB")
    if ub is None or dtb is None:
        raise SandboxUnavailable("UBOOT_SANDBOX and/or CM4_BASE_DTB not set")
    uboot = ub / "u-boot"
    mkimage = ub / "tools" / "mkimage"
    for p in (uboot, mkimage, dtb):
        if not p.exists():
            raise SandboxUnavailable(f"missing: {p}")
    for tool in ("sgdisk", "mkfs.ext4", "dtc", "fdtget"):
        if shutil.which(tool) is None:
            raise SandboxUnavailable(f"tool not on PATH: {tool}")
    return uboot, mkimage, dtb


# --- script rewriting -------------------------------------------------------

_RE_BOOTI = re.compile(r"^([ \t]*)booti[ \t]+(\S+)[ \t]+-[ \t]+(\S+)[ \t]*$",
                       re.M)
_RE_WDT = re.compile(r"^wdt ", re.M)
_RE_RESET = re.compile(r"^([ \t]*)reset[ \t]*$", re.M)
_RE_SAVEENV = re.compile(r"^([ \t]*)saveenv[ \t]*$", re.M)
_DEVTYPE_MMC = "setenv oe5xrx_devtype mmc"


def rewrite_for_sandbox(script: str, *, stage1: bool) -> str:
    """Replace the hardware-facing commands by sandbox indirections.

    Every rule must hit at least once (stage 1: booti, wdt, reset, saveenv,
    devtype; stage 2: booti) — a script edit that moves a command out of
    reach of the rules fails loudly instead of silently running the real
    command (or not testing it)."""
    s, n = _RE_BOOTI.subn(
        r"\1setenv oe5xrx_t_kernel \2; setenv oe5xrx_t_fdt \3; "
        r"run oe5xrx_t_booti", script)
    hits = {"booti": n}
    if stage1:
        s, hits["wdt"] = _RE_WDT.subn("echo OE5XRX_T_WDT ", s)
        s, hits["reset"] = _RE_RESET.subn(r"\1run oe5xrx_t_reset", s)
        s, hits["saveenv"] = _RE_SAVEENV.subn(r"\1run oe5xrx_t_saveenv", s)
        hits["devtype"] = s.count(_DEVTYPE_MMC)
        s = s.replace(_DEVTYPE_MMC, "setenv oe5xrx_devtype host")
    missing = [k for k, v in hits.items() if v < 1]
    assert not missing, f"rewrite rules without a hit: {missing}"
    return s


def find_mkimage() -> Path | None:
    """mkimage from UBOOT_SANDBOX/tools, else PATH (u-boot-tools), else None
    (absolute)."""
    ub = env_path("UBOOT_SANDBOX")
    if ub is not None and (ub / "tools" / "mkimage").exists():
        return ub / "tools" / "mkimage"
    m = shutil.which("mkimage")
    return Path(m).resolve() if m else None


def compile_script(text: str, out: Path, mkimage: Path | None = None) -> None:
    """mkimage -T script (legacy image, like the u-boot-ab recipe)."""
    if mkimage is None:
        mkimage = sandbox_paths()[1]
    with tempfile.NamedTemporaryFile("w", suffix=".cmd", delete=False) as f:
        f.write(text)
        src = f.name
    try:
        subprocess.run([str(mkimage), "-q", "-A", "arm64", "-O", "linux",
                        "-T", "script", "-C", "none", "-d", src, str(out)],
                       check=True, stdout=subprocess.DEVNULL, timeout=30)
    finally:
        os.unlink(src)


def script_bytes(text: str, mkimage: Path | None = None) -> bytes:
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "s.scr"
        compile_script(text, out, mkimage)
        return out.read_bytes()


def compile_dtbo(dts: Path) -> bytes:
    r = subprocess.run(["dtc", "-@", "-q", "-I", "dts", "-O", "dtb", str(dts)],
                       check=True, capture_output=True, timeout=30)
    return r.stdout


# --- disk image -------------------------------------------------------------

@dataclass(frozen=True)
class Symlink:
    """A symlink entry in a rootfs file map (mkfs.ext4 -d keeps it as one),
    e.g. /boot/Image -> Image-<KERNEL_VERSION> as OE-core installs it."""
    target: str


def write_tree(root: Path, files: dict[str, bytes | Symlink]) -> None:
    """Materialize a rootfs file map {"/abs/path": bytes | Symlink}."""
    for name, content in files.items():
        p = root / name.lstrip("/")
        p.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, Symlink):
            os.symlink(content.target, p)
        else:
            p.write_bytes(content)


def make_test_disk(path, slots: dict[str, dict[str, bytes | Symlink]]) -> None:
    """GPT image with the wks partition layout; `slots` maps "a"/"b" to
    {"/abs/path/in/rootfs": content | Symlink}. Slots not listed stay
    unformatted."""
    path = Path(path)
    unknown = set(slots) - {"a", "b"}
    assert not unknown, f"unknown slots: {unknown}"
    start = _MIB // _SECTOR  # 1 MiB alignment like wks --align
    layout = []
    args = ["sgdisk", "-o"]
    for num, (label, mib) in enumerate(_PARTITIONS, start=1):
        end = start + mib * _MIB // _SECTOR - 1
        args += [f"-n{num}:{start}:{end}", f"-c{num}:{label}"]
        layout.append((label, start, mib))
        start = end + 1
    total = start * _SECTOR + _MIB  # room for the backup GPT
    with open(path, "wb") as f:
        f.truncate(total)
    subprocess.run(args + [str(path)], check=True, capture_output=True,
                   timeout=30)
    for label, first, mib in layout:
        if not label.startswith("root_") or label[-1] not in slots:
            continue
        files = slots[label[-1]]
        with tempfile.TemporaryDirectory() as d:
            root = Path(d) / "root"
            root.mkdir()
            write_tree(root, files)
            fs = Path(d) / "fs.img"
            with open(fs, "wb") as f:
                f.truncate(mib * _MIB)
            subprocess.run(["mkfs.ext4", "-q", "-F", "-L", label,
                            "-d", str(root), str(fs)],
                           check=True, capture_output=True, timeout=60)
            subprocess.run(["dd", f"if={fs}", f"of={path}", "bs=512",
                            f"seek={first}", "conv=notrunc", "status=none"],
                           check=True, timeout=60)


# --- boot -------------------------------------------------------------------

@dataclass(frozen=True)
class BootiReject:
    """Which booti calls RETURN (like a real booti rejecting the Image/DTB)
    instead of booting. A call is rejected if any rule matches: `all`, it is
    one of the first `first` calls of this boot (1-based, <= 9), or its
    expanded fdt argument is in `fdt` (e.g. FDT_ADDR = the firmware DTB)."""
    all: bool = False
    first: int = 0
    fdt: tuple[str, ...] = ()

    def hush(self) -> str:
        """Commands setting oe5xrx_t_rej=1 for a rejected call (part of the
        single-quoted oe5xrx_t_booti: no single quotes in here)."""
        assert 0 <= self.first <= 9  # setexpr counts in hex
        rules = []
        if self.all:
            rules.append("setenv oe5xrx_t_rej 1")
        if self.first:
            rules.append(f"if test ${{oe5xrx_t_n}} -le {self.first}; then "
                         "setenv oe5xrx_t_rej 1; fi")
        for a in self.fdt:
            assert re.fullmatch(r"0x[0-9a-fA-F]+", a), a
            rules.append(f'if test "${{oe5xrx_t_fdt}}" = "{a}"; then '
                         "setenv oe5xrx_t_rej 1; fi")
        return "; ".join(rules)


@dataclass
class BootResult:
    booted: bool
    reset: bool
    bootargs: str
    kernel: bytes                 # first 16 bytes at booti's kernel address
    fdt_path: Path | None         # DTB handed to booti
    fdt_addr_after: Path | None   # DTB at ${fdt_addr} at booti time
    env: dict[str, str]           # persisted env (env.txt) after this boot
    output: str
    booti_kernel_addr: str = ""   # booti's literal (expanded) arguments
    booti_fdt_addr: str = ""
    # (kernel, fdt) of every booti call that returned (BootiReject), in order
    rejected_booti: list[tuple[str, str]] = field(default_factory=list)
    returncode: int = 0
    extra: dict = field(default_factory=dict)


def _write_env(path: Path, env: dict[str, str]) -> None:
    for k, v in env.items():
        assert re.fullmatch(r"[A-Za-z0-9_]+", k) and "\n" not in v, (k, v)
    path.write_text("".join(f"{k}={v}\n" for k, v in env.items()))


def _read_env(path: Path) -> dict[str, str]:
    env = {}
    for line in path.read_bytes().replace(b"\0", b"").decode().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            env[k] = v
    return env


def run_boot(workdir, disk, stage1_text: str, base_dtb,
             env: dict[str, str], *, uboot: Path | None = None,
             mkimage: Path | None = None,
             reject_booti: BootiReject | None = None,
             fdt_addr: str | None = FDT_ADDR) -> BootResult:
    """One simulated boot: prelude -> source (rewritten) stage 1.

    `stage1_text` is the RAW stage-1 text (rewritten here). Stage 2 lives in
    the disk image (caller renders, rewrites with stage1=False, compiles).
    `env` = persisted env before this boot (written to env.txt).
    `reject_booti`: booti calls that return instead of booting.
    `fdt_addr=None`: the firmware passed no DTB (${fdt_addr} unset)."""
    if uboot is None or mkimage is None:
        u, m, _ = sandbox_paths()
        uboot = uboot or u
        mkimage = mkimage or m
    # The sandbox runs with cwd=w: every path it sees must be absolute.
    uboot = Path(uboot).resolve()
    mkimage = Path(mkimage).resolve()
    w = Path(workdir).resolve()
    w.mkdir(parents=True, exist_ok=True)
    disk = Path(disk).resolve()
    base_dtb = Path(base_dtb).resolve()
    env_txt = w / "env.txt"
    out_fdt = w / "booti-fdt.dtb"
    out_base = w / "fdt-addr-after.dtb"
    out_kernel = w / "booti-kernel.bin"
    for p in (out_fdt, out_base, out_kernel):
        p.unlink(missing_ok=True)
    _write_env(env_txt, env)

    compile_script(rewrite_for_sandbox(stage1_text, stage1=True),
                   w / "stage1.scr", mkimage)

    env_import = (
        f"host load hostfs - {_ENV_ADDR} {env_txt}\n"
        f"env import -t {_ENV_ADDR} ${{filesize}}\n") if env else ""
    persisted = " ".join(PERSISTED_VARS)
    if fdt_addr is None:
        firmware_dtb = "setenv fdt_addr\n"
    else:
        firmware_dtb = (f"setenv fdt_addr {fdt_addr}\n"
                        f"host load hostfs - ${{fdt_addr}} {base_dtb}\n")
    boot_now = (
        "echo OE5XRX_T_BOOTI kernel=${oe5xrx_t_kernel} fdt=${oe5xrx_t_fdt}; "
        "echo OE5XRX_T_BOOTARGS ${bootargs}; "
        f"host save hostfs - ${{oe5xrx_t_kernel}} {out_kernel} 0x10; "
        "setenv oe5xrx_t_sz; fdt addr ${oe5xrx_t_fdt} && "
        "fdt header get oe5xrx_t_sz totalsize && "
        f"host save hostfs - ${{oe5xrx_t_fdt}} {out_fdt} ${{oe5xrx_t_sz}}; "
        'setenv oe5xrx_t_sz; test -n "${fdt_addr}" && fdt addr ${fdt_addr} && '
        "fdt header get oe5xrx_t_sz totalsize && "
        f"host save hostfs - ${{fdt_addr}} {out_base} ${{oe5xrx_t_sz}}; "
        "poweroff")
    rules = reject_booti.hush() if reject_booti else ""
    if rules:
        # A rejected call returns non-zero, like a real failed booti.
        booti = (
            "setexpr oe5xrx_t_n ${oe5xrx_t_n} + 1; setenv oe5xrx_t_rej 0; "
            f"{rules}; if test ${{oe5xrx_t_rej}} = 1; then "
            "echo OE5XRX_T_BOOTI_REJECTED kernel=${oe5xrx_t_kernel} "
            f"fdt=${{oe5xrx_t_fdt}}; test 1 = 0; else {boot_now}; fi")
    else:
        booti = boot_now
    assert "'" not in booti
    prelude = f"""\
setenv kernel_addr_r {KERNEL_ADDR_R}
setenv scriptaddr {SCRIPTADDR}
setenv fdt_addr_r {FDT_ADDR_R}
setenv ramdisk_addr_r {RAMDISK_ADDR_R}
{firmware_dtb}\
{env_import}\
setenv oe5xrx_t_n 0
setenv oe5xrx_t_booti '{booti}'
setenv oe5xrx_t_saveenv 'echo OE5XRX_T_SAVEENV; env export -t {_ENV_ADDR} {persisted} && host save hostfs - {_ENV_ADDR} {env_txt} ${{filesize}}'
setenv oe5xrx_t_reset 'echo OE5XRX_T_RESET; poweroff'
host bind 0 {disk}
host load hostfs - {_STAGE1_ADDR} {w / "stage1.scr"}
source {_STAGE1_ADDR}
echo OE5XRX_T_SCRIPT_END
poweroff
"""
    (w / "prelude.cmd").write_text(prelude)
    compile_script(prelude, w / "prelude.scr", mkimage)

    r = subprocess.run(
        ["timeout", str(BOOT_TIMEOUT_S), str(uboot), "-c",
         f"host load hostfs - {_PRELUDE_ADDR} {w / 'prelude.scr'}; "
         f"source {_PRELUDE_ADDR}"],
        stdin=subprocess.DEVNULL, capture_output=True, text=True,
        errors="replace", cwd=w, timeout=BOOT_TIMEOUT_S + 10)
    output = r.stdout + r.stderr
    (w / "output.log").write_text(output)
    if r.returncode != 0:
        raise AssertionError(f"sandbox exited {r.returncode}:\n{output}")

    m = re.search(r"^OE5XRX_T_BOOTI kernel=(\S*) fdt=(\S*)", output, re.M)
    booted = m is not None
    ba = re.search(r"^OE5XRX_T_BOOTARGS ?(.*)$", output, re.M)
    return BootResult(
        booted=booted,
        reset=re.search(r"^OE5XRX_T_RESET", output, re.M) is not None,
        bootargs=ba.group(1) if (booted and ba) else "",
        kernel=out_kernel.read_bytes() if out_kernel.exists() else b"",
        fdt_path=out_fdt if out_fdt.exists() else None,
        fdt_addr_after=out_base if out_base.exists() else None,
        env=_read_env(env_txt),
        output=output,
        booti_kernel_addr=m.group(1) if m else "",
        booti_fdt_addr=m.group(2) if m else "",
        rejected_booti=re.findall(
            r"^OE5XRX_T_BOOTI_REJECTED kernel=(\S*) fdt=(\S*)", output, re.M),
        returncode=r.returncode,
    )


def fdtget(dtb: Path, node: str, prop: str) -> str | None:
    """fdtget value, or None if node/property is absent."""
    r = subprocess.run(["fdtget", str(dtb), node, prop],
                       capture_output=True, text=True, timeout=30)
    return r.stdout.strip() if r.returncode == 0 else None
