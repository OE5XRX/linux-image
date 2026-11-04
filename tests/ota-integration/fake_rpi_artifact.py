"""Build a FAKE raspberrypi4-64 artifact dir for running test_rpi_artifact.py
locally (no Yocto build needed). TEST TOOLING ONLY — never used by a build.

    python3 tests/ota-integration/fake_rpi_artifact.py OUTDIR [--fault F]

Writes OUTDIR/oe5xrx-remotestation-image-raspberrypi4-64.rootfs.wic.bz2 with
the wks GPT layout (firmware vfat, uboot_env, uboot_envr, root_a ext4,
root_b empty, data ext4) built from the repo sources the same way the
recipes do: FAT boot.scr = mkimage(boot.cmd), config.txt, the CM4 DTB
(CM4_BASE_DTB); root_a /boot/boot-stage2.scr = mkimage(render_stage2(...)),
/boot/overlays/<name>.dtbo = dtc -@, /boot/Image stub (arm64 header).

--fault injects one defect the gate must catch (manual negative check):
  test-overlay   rootfs + stage 2 additionally carry oe5xrx-test-marker
  stage2-broken  stage 2 = boot-stage2-test-broken.cmd ("OE5XRX TEST FAULT")
  fat-dtoverlay  config.txt carries dtoverlay=oe5xrx-ina226
  fat-overlay    FAT carries overlays/oe5xrx-ina226.dtbo
  fat-root-overlay  FAT root carries OE5XRX-INA226.DTBO
  kernel-too-big    /boot/Image header image_size overlaps scriptaddr
Needs: mkimage (UBOOT_SANDBOX/tools or PATH), dtc, sgdisk, mkfs.vfat, mcopy,
mkfs.ext4, bzip2 (python), CM4_BASE_DTB.
"""

from __future__ import annotations

import argparse
import bz2
import os
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from boot_scripts import (  # noqa: E402
    STAGE2_TEMPLATE, read_stage1, read_stage2_template, render_stage2)
from rpi_artifact import release_overlays  # noqa: E402
from uboot_sandbox import (  # noqa: E402
    compile_dtbo, find_mkimage, script_bytes)

_REPO = Path(__file__).resolve().parents[2]
_OVERLAY_DIR = (_REPO / "meta-oe5xrx-remotestation" / "recipes-bsp"
                / "oe5xrx-dt-overlays" / "files")
_MIB = 1024 * 1024
# (label, MiB, kind) in wks order; sizes shrunk, order/labels as the wks.
_LAYOUT = (("firmware", 8, "vfat"), ("uboot_env", 1, None),
           ("uboot_envr", 1, None), ("root_a", 24, "ext4"),
           ("root_b", 24, None), ("data", 4, "ext4"))
_CONFIG_TXT = """\
# fake config.txt (meta-raspberrypi style)
arm_64bit=1
enable_uart=1
kernel=u-boot.bin
otg_mode=1
"""


def _mkimage() -> Path:
    m = find_mkimage()
    if m is None:
        sys.exit("mkimage not found (UBOOT_SANDBOX/tools or PATH)")
    return m


def build(outdir: Path, fault: str | None) -> Path:
    dtb = os.environ.get("CM4_BASE_DTB")
    if not dtb or not Path(dtb).exists():
        sys.exit("CM4_BASE_DTB must point at a CM4 DTB (FAT stand-in)")
    mkimage = _mkimage()
    overlays = release_overlays()
    if fault == "test-overlay":
        overlays = overlays + ["oe5xrx-test-marker"]
    if fault == "stage2-broken":
        stage2 = (Path(STAGE2_TEMPLATE).parent
                  / "boot-stage2-test-broken.cmd").read_text()
    else:
        stage2 = render_stage2(read_stage2_template(), overlays)

    fat = {"/boot.scr": script_bytes(read_stage1(), mkimage),
           "/config.txt": _CONFIG_TXT.encode(),
           "/bcm2711-rpi-cm4.dtb": Path(dtb).read_bytes(),
           "/overlays/vc4-kms-v3d.dtbo": b"not-a-real-dtbo"}
    if fault == "fat-dtoverlay":
        fat["/config.txt"] += b"dtoverlay=oe5xrx-ina226\n"
    if fault == "fat-overlay":
        fat["/overlays/oe5xrx-ina226.dtbo"] = compile_dtbo(
            _OVERLAY_DIR / "oe5xrx-ina226-overlay.dts")
    if fault == "fat-root-overlay":
        fat["/OE5XRX-INA226.DTBO"] = compile_dtbo(
            _OVERLAY_DIR / "oe5xrx-ina226-overlay.dts")
    # arm64 Image header (text_offset 0, flags 0xa) so the gate's booti
    # layout check has something real to parse.
    image_size = 0x5400000 if fault == "kernel-too-big" else 0x2000000
    image = struct.pack("<IIQQQQQQII", 0, 0, 0, image_size, 0xA, 0, 0, 0,
                        0x644D5241, 0) + b"KERNEL-STUB" + bytes(4096)
    root = {"/boot/Image": image,
            "/boot/boot-stage2.scr": script_bytes(stage2, mkimage),
            "/boot/boot-stage2.cmd": stage2.encode()}
    for name in overlays:
        root[f"/boot/overlays/{name}.dtbo"] = compile_dtbo(
            _OVERLAY_DIR / f"{name}-overlay.dts")

    outdir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        img = d / "disk.wic"
        start = _MIB // 512
        args = ["sgdisk", "-o"]
        spans = []
        for num, (label, mib, kind) in enumerate(_LAYOUT, start=1):
            end = start + mib * _MIB // 512 - 1
            args += [f"-n{num}:{start}:{end}", f"-c{num}:{label}"]
            spans.append((label, start, mib, kind))
            start = end + 1
        with open(img, "wb") as f:
            f.truncate(start * 512 + _MIB)
        subprocess.run(args + [str(img)], check=True, capture_output=True)
        for label, first, mib, kind in spans:
            if kind is None:
                continue
            fs = d / f"{label}.img"
            with open(fs, "wb") as f:
                f.truncate(mib * _MIB)
            if kind == "vfat":
                subprocess.run(["mkfs.vfat", "-n", "BOOT", str(fs)],
                               check=True, capture_output=True)
                env = {**os.environ, "MTOOLS_SKIP_CHECK": "1"}
                subprocess.run(["mmd", "-i", str(fs), "::/overlays"],
                               check=True, env=env)
                for p, content in fat.items():
                    src = d / "fatfile"
                    src.write_bytes(content)
                    subprocess.run(["mcopy", "-i", str(fs), str(src),
                                    f"::{p}"], check=True, env=env)
            else:
                tree = d / f"{label}-tree"
                for p, content in (root if label == "root_a" else {}).items():
                    q = tree / p.lstrip("/")
                    q.parent.mkdir(parents=True, exist_ok=True)
                    q.write_bytes(content)
                tree.mkdir(exist_ok=True)
                subprocess.run(["mkfs.ext4", "-q", "-F", "-L", label, "-d",
                                str(tree), str(fs)], check=True,
                               capture_output=True)
            subprocess.run(["dd", f"if={fs}", f"of={img}", "bs=512",
                            f"seek={first}", "conv=notrunc", "status=none"],
                           check=True)
        out = outdir / "oe5xrx-remotestation-image-raspberrypi4-64.rootfs.wic.bz2"
        with open(img, "rb") as fin, bz2.open(out, "wb") as fout:
            shutil.copyfileobj(fin, fout)
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("outdir", type=Path)
    ap.add_argument("--fault", choices=("test-overlay", "stage2-broken",
                                        "fat-dtoverlay", "fat-overlay",
                                        "fat-root-overlay", "kernel-too-big"))
    a = ap.parse_args()
    print(build(a.outdir, a.fault))


if __name__ == "__main__":
    main()
