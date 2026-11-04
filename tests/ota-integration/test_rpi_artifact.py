"""Release gate against the REAL raspberrypi4-64 build artifact (spec §7).

Marker `rpi_artifact` (release.yml job rpi-artifact-gate): RPI_ARTIFACT_DIR
points at the downloaded `yocto-image-raspberrypi4-64` artifact; the wic the
release job will publish is inspected without mounting:

  - root_a carries /boot/boot-stage2.scr + exactly the release overlays
    (/boot/overlays/oe5xrx-*.dtbo), no oe5xrx-test-* overlay
  - the FAT carries none of our overlays (no dtoverlay=oe5xrx- in
    config.txt, no overlays/oe5xrx-*) and boot.scr == repo boot.cmd
  - the shipped stage 2 is the rendered template (no "OE5XRX TEST FAULT",
    no test overlay — however it got there)
  - the FAT CM4 DTB has __symbols__ and every shipped overlay applies
    (fdtoverlay); INA226 @40/@41 with shunt-resistor 10000
  - /boot/Image (a symlink to Image-<KERNEL_VERSION>, followed; file size
    and booti's relocated image_size) ends below scriptaddr with the rpi load addresses
  - the BUILT boot.scr + boot-stage2.scr + dtbo + FAT DTB boot in the U-Boot
    sandbox (needs UBOOT_SANDBOX): stage2=ok, overlays=ok:<list>, INA226 nodes

Skipped locally without RPI_ARTIFACT_DIR, a hard failure in CI. Locally:
`python3 tests/ota-integration/fake_rpi_artifact.py DIR` builds a fake one.
The `unit` tests here (script_text, Image header, wic decompression, ext4
symlink reads) run in every PR.
"""

from __future__ import annotations

import os
import re
import shutil
import struct
import subprocess
import zlib
from pathlib import Path

import pytest
from boot_scripts import read_stage1, read_stage2_template, render_stage2
from rpi_artifact import (
    Arm64Image,
    Partition,
    arm64_image_header,
    booti_relocated_addr,
    ext4_list,
    ext4_read,
    fat_list,
    fat_read,
    materialize_wic,
    missing_tools,
    parallel_bz2_tool,
    pick_wic,
    read_gpt,
    release_overlays,
    script_text,
)
from uboot_sandbox import (
    FDT_ADDR_R,
    KERNEL_ADDR_R,
    SCRIPTADDR,
    Symlink,
    compile_script,
    fdtget,
    find_mkimage,
    make_test_disk,
    rewrite_for_sandbox,
    run_boot,
    script_bytes,
    write_tree,
)

INA = "oe5xrx-ina226"
FAT_DTB = "/bcm2711-rpi-cm4.dtb"
TEST_FAULT = "OE5XRX TEST FAULT"


def _unavailable(msg: str):
    if os.environ.get("CI"):
        pytest.fail(f"rpi artifact gate cannot run in CI: {msg}")
    pytest.skip(msg)


# --- fixtures -----------------------------------------------------------------

@pytest.fixture(scope="session")
def wic(tmp_path_factory):
    d = os.environ.get("RPI_ARTIFACT_DIR")
    if not d:
        _unavailable("RPI_ARTIFACT_DIR not set")
    if not Path(d).is_dir():
        _unavailable(f"RPI_ARTIFACT_DIR is not a directory: {d}")
    if missing_tools():
        _unavailable(f"tools not on PATH: {missing_tools()}")
    src = pick_wic(Path(d))
    img = materialize_wic(src, tmp_path_factory.mktemp("wic"))
    parts = read_gpt(img)
    for label in ("firmware", "root_a"):
        assert label in parts, f"{src.name}: no PARTLABEL {label}: {parts}"
    return {"img": img, "src": src, "parts": parts}


@pytest.fixture(scope="session")
def fat(wic):
    return lambda p: fat_read(wic["img"], wic["parts"]["firmware"], p)


@pytest.fixture(scope="session")
def root_a(wic):
    return lambda p: ext4_read(wic["img"], wic["parts"]["root_a"], p)


@pytest.fixture(scope="session")
def stage2_text(root_a):
    scr = root_a("/boot/boot-stage2.scr")
    assert scr is not None, "root_a has no /boot/boot-stage2.scr"
    return script_text(scr)


@pytest.fixture(scope="session")
def shipped_overlays(wic):
    names = ext4_list(wic["img"], wic["parts"]["root_a"], "/boot/overlays")
    assert names is not None, "root_a has no /boot/overlays"
    return sorted(n[:-len(".dtbo")] for n in names
                  if n.startswith("oe5xrx-") and n.endswith(".dtbo"))


@pytest.fixture(scope="session")
def base_dtb(fat, tmp_path_factory):
    blob = fat(FAT_DTB)
    assert blob is not None, f"FAT has no {FAT_DTB}"
    p = tmp_path_factory.mktemp("dtb") / "bcm2711-rpi-cm4.dtb"
    p.write_bytes(blob)
    return p


# --- static artifact checks ---------------------------------------------------

@pytest.mark.rpi_artifact
def test_rootfs_carries_stage2_and_overlays(wic, root_a, shipped_overlays):
    boot = ext4_list(wic["img"], wic["parts"]["root_a"], "/boot")
    assert boot is not None and "Image" in boot, boot
    assert root_a("/boot/boot-stage2.scr"), "no /boot/boot-stage2.scr"
    assert root_a(f"/boot/overlays/{INA}.dtbo"), f"no {INA}.dtbo"
    test = [o for o in shipped_overlays if o.startswith("oe5xrx-test-")]
    assert not test, f"test overlay(s) in a release rootfs: {test}"
    assert shipped_overlays == sorted(release_overlays()), shipped_overlays


@pytest.mark.rpi_artifact
def test_fat_has_no_own_overlays(wic, fat):
    files = fat_list(wic["img"], wic["parts"]["firmware"])
    # Anywhere on the FAT (root, overlays/, any subdir), any case.
    own = [f for f in files if re.search(r"(^|/)oe5xrx-.*\.dtbo$", f, re.I)]
    assert not own, f"own overlays on the FAT (belong in the slot): {own}"
    cfg = fat("/config.txt")
    assert cfg is not None, "FAT has no config.txt"
    bad = [ln for ln in cfg.decode(errors="replace").splitlines()
           if not ln.lstrip().startswith("#")
           and re.search(r"dtoverlay\s*=.*oe5xrx-", ln)]
    assert not bad, f"config.txt loads our overlays: {bad}"
    scr = fat("/boot.scr")
    assert scr is not None, "FAT has no boot.scr"
    assert script_text(scr) == read_stage1(), (
        "FAT boot.scr is not the repo's stage 1 (boot.cmd)")


@pytest.mark.rpi_artifact
def test_release_stage2_has_no_test_fault(stage2_text):
    assert TEST_FAULT not in stage2_text
    assert "oe5xrx-test-" not in stage2_text
    # The recipe's sed rendering == boot_scripts.render_stage2 for the
    # release overlay list — byte for byte.
    assert stage2_text == render_stage2(read_stage2_template(),
                                        release_overlays())


@pytest.mark.rpi_artifact
def test_base_dtb_has_symbols_and_overlay_applies(root_a, base_dtb,
                                                  shipped_overlays, tmp_path):
    i2c1 = fdtget(base_dtb, "/__symbols__", "i2c1")
    assert i2c1, "FAT CM4 DTB has no /__symbols__/i2c1 (overlays unresolvable)"
    dtbos = []
    for name in shipped_overlays:
        p = tmp_path / f"{name}.dtbo"
        p.write_bytes(root_a(f"/boot/overlays/{name}.dtbo"))
        dtbos.append(str(p))
    out = tmp_path / "merged.dtb"
    subprocess.run(["fdtoverlay", "-i", str(base_dtb), "-o", str(out),
                    *dtbos], check=True, timeout=60)
    for addr in ("40", "41"):
        node = f"{i2c1}/ina226@{addr}"
        assert fdtget(out, node, "shunt-resistor") == "10000", node


@pytest.mark.rpi_artifact
def test_kernel_image_fits_below_scriptaddr(root_a):
    # boot-stage2.cmd.in "Memory layout": with the rpi load addresses the
    # loaded file AND booti's relocated copy (image_size incl. BSS) must end
    # at or below scriptaddr, else the DTB copy at fdt_addr_r is clobbered.
    blob = root_a("/boot/Image")
    assert blob, "root_a has no /boot/Image"
    img = arm64_image_header(blob)
    load, limit = int(KERNEL_ADDR_R, 16), int(SCRIPTADDR, 16)
    reloc = booti_relocated_addr(load, img)
    assert load + len(blob) <= limit, (
        f"Image file ({len(blob):#x} bytes at {load:#x}) overlaps "
        f"scriptaddr {limit:#x}")
    assert reloc + img.image_size <= limit, (
        f"booti copy [{reloc:#x}, {reloc + img.image_size:#x}) overlaps "
        f"scriptaddr {limit:#x} ({img})")


# --- sandbox boot of the built scripts ---------------------------------------

def _sandbox_bins():
    ub = os.environ.get("UBOOT_SANDBOX")
    if not ub:
        _unavailable("UBOOT_SANDBOX not set")
    uboot, mkimage = Path(ub) / "u-boot", Path(ub) / "tools" / "mkimage"
    for p in (uboot, mkimage):
        if not p.exists():
            _unavailable(f"missing: {p}")
    for tool in ("sgdisk", "mkfs.ext4", "dtc", "fdtget"):
        if shutil.which(tool) is None:
            _unavailable(f"tool not on PATH: {tool}")
    return uboot, mkimage


@pytest.mark.rpi_artifact
def test_sandbox_boot_with_built_scripts(fat, root_a, stage2_text, base_dtb,
                                         shipped_overlays, tmp_path):
    uboot, mkimage = _sandbox_bins()
    stage1 = script_text(fat("/boot.scr"))
    kernel = b"KERNEL-SLOT-A..." + bytes(4080)
    files = {
        # real layout: /boot/Image -> Image-<KERNEL_VERSION>
        "/boot/Image-6.12.47-v8": kernel,
        "/boot/Image": Symlink("Image-6.12.47-v8"),
        "/boot/boot-stage2.scr": script_bytes(
            rewrite_for_sandbox(stage2_text, stage1=False), mkimage),
    }
    for name in shipped_overlays:
        files[f"/boot/overlays/{name}.dtbo"] = root_a(
            f"/boot/overlays/{name}.dtbo")
    disk = tmp_path / "disk.img"
    make_test_disk(disk, {"a": files, "b": files})
    r = run_boot(tmp_path / "boot", disk, stage1, base_dtb, {},
                 uboot=uboot, mkimage=mkimage)

    assert r.booted and not r.reset, r.output
    assert r.kernel == kernel[:16], r.output
    assert r.booti_kernel_addr == KERNEL_ADDR_R
    assert r.booti_fdt_addr == FDT_ADDR_R, r.output  # stage 2's DTB copy
    assert "root=PARTLABEL=root_a " in r.bootargs, r.bootargs
    assert re.findall(r"(?:^| )oe5xrx\.stage2=(\S*)", r.bootargs) == ["ok"]
    csv = ",".join(release_overlays())
    assert re.findall(r"(?:^| )oe5xrx\.overlays=(\S*)", r.bootargs) == [
        f"ok:{csv}"], r.bootargs
    assert f"ok:{INA}" in r.bootargs
    i2c1 = fdtget(base_dtb, "/__symbols__", "i2c1")
    for addr in ("40", "41"):
        assert fdtget(r.fdt_path, f"{i2c1}/ina226@{addr}",
                      "shunt-resistor") == "10000"
    # firmware DTB at ${fdt_addr} untouched (overlays only on the copy)
    assert r.fdt_addr_after.read_bytes() == base_dtb.read_bytes()
    assert r.env.get("bootcount") == "1", r.env


# --- unit: arm64 Image header / booti relocation -------------------------------

def _arm64_hdr(text_offset, image_size, flags, magic=0x644D5241):
    return struct.pack("<IIQQQQQQII", 0, 0, text_offset, image_size, flags,
                       0, 0, 0, magic, 0)


@pytest.mark.unit
def test_arm64_image_header_and_booti_relocation():
    img = arm64_image_header(_arm64_hdr(0, 0x2000000, 0xA) + bytes(16))
    assert img == Arm64Image(0, 0x2000000, 0xA)
    # flags bit 3 (anywhere): 2 MiB-aligned above the load address
    assert booti_relocated_addr(0x80000, img) == 0x200000
    assert booti_relocated_addr(0x200000, img) == 0x200000
    # text_offset 0x80000 loaded at a 2 MiB boundary + 0x80000: no move
    old = Arm64Image(0x80000, 0x2000000, 0xA)
    assert booti_relocated_addr(0x80000, old) == 0x80000
    # bit 3 clear: base of DRAM (0 on the CM4) + text_offset
    assert booti_relocated_addr(0x1000000, Arm64Image(0, 0x100, 0x2)) == 0
    # image_size 0 (pre-3.17): booti assumes 16 MiB at text_offset 0x80000
    assert arm64_image_header(_arm64_hdr(7, 0, 0)) == Arm64Image(
        0x80000, 16 << 20, 0)
    with pytest.raises(ValueError, match="magic"):
        arm64_image_header(_arm64_hdr(0, 1, 0, magic=0))
    with pytest.raises(ValueError, match="short"):
        arm64_image_header(b"\0" * 10)


# --- unit: legacy script image unwrapping -------------------------------------

@pytest.mark.unit
def test_script_text_strips_mkimage_header(tmp_path):
    mkimage = find_mkimage()
    if mkimage is None:
        pytest.skip("mkimage not available (u-boot-tools)")
    text = read_stage1()
    out = tmp_path / "boot.scr"
    compile_script(text, out, mkimage)
    scr = out.read_bytes()
    assert script_text(scr) == text

    with pytest.raises(ValueError, match="magic"):
        script_text(b"\0" * 4 + scr[4:])
    with pytest.raises(ValueError, match="header CRC"):
        script_text(scr[:40] + b"X" + scr[41:])
    with pytest.raises(ValueError, match="data CRC"):
        script_text(scr[:-1] + bytes([scr[-1] ^ 0xFF]))
    with pytest.raises(ValueError, match="truncated"):
        script_text(scr[:-1])
    # type byte (offset 30) != script, header CRC fixed up
    hdr = bytearray(scr[:64])
    hdr[30] = 2
    hdr[4:8] = b"\0\0\0\0"
    hdr[4:8] = struct.pack(">I", zlib.crc32(hdr))
    with pytest.raises(ValueError, match="not a script"):
        script_text(bytes(hdr) + scr[64:])


# --- unit: wic decompression (parallel bzip2 tool vs. Python bz2) ---------------

def _sample_wic() -> bytes:
    # zero runs (sparse holes), data across chunk boundaries, odd tail
    mib = 1024 * 1024
    return (b"\0" * (2 * mib) + os.urandom(mib + 17) + b"\0" * (3 * mib)
            + b"tail" + b"\0" * 5)


@pytest.mark.unit
def test_materialize_wic_bz2_python_fallback(tmp_path, monkeypatch):
    import bz2
    import rpi_artifact
    raw = _sample_wic()
    # two concatenated streams, as pbzip2/lbzip2 may write
    half = len(raw) // 2
    src = tmp_path / "x.wic.bz2"
    src.write_bytes(bz2.compress(raw[:half]) + bz2.compress(raw[half:]))
    monkeypatch.setattr(rpi_artifact, "parallel_bz2_tool", lambda: None)
    out = materialize_wic(src, tmp_path)
    assert out.name == "x.wic"
    assert out.read_bytes() == raw
    # sparse: the zero runs were seeked over, not written
    assert out.stat().st_blocks * 512 < len(raw)


@pytest.mark.unit
def test_materialize_wic_bz2_parallel_tool(tmp_path):
    import bz2
    tool = parallel_bz2_tool()
    if tool is None:
        pytest.skip("no lbzip2/pbzip2 on PATH")
    raw = _sample_wic()
    half = len(raw) // 2
    src = tmp_path / "x.wic.bz2"
    src.write_bytes(bz2.compress(raw[:half]) + bz2.compress(raw[half:]))
    out = materialize_wic(src, tmp_path)
    assert out.read_bytes() == raw
    assert out.stat().st_blocks * 512 < len(raw)

    bad = tmp_path / "bad.wic.bz2"
    bad.write_bytes(src.read_bytes()[:-50])  # truncated stream
    with pytest.raises(RuntimeError, match="-dc"):
        materialize_wic(bad, tmp_path)


@pytest.mark.unit
def test_materialize_wic_tool_failure_raises(tmp_path):
    src = tmp_path / "x.wic.bz2"
    src.write_bytes(b"not bzip2")
    with pytest.raises(RuntimeError, match="rc 1"):
        materialize_wic(src, tmp_path, bz2_tool=shutil.which("false"))


# --- unit: ext4 reads through symlinks (debugfs dump does not follow them) ----

@pytest.mark.unit
def test_ext4_read_follows_symlinks(tmp_path):
    for tool in ("mkfs.ext4", "debugfs"):
        if shutil.which(tool) is None:
            pytest.skip(f"{tool} not on PATH (e2fsprogs)")
    blob = os.urandom(70000)
    slow = "/boot/" + "L" * 80  # > 60 bytes: target in a data block
    files = {
        "/boot/Image-6.12.47-v8": blob,
        "/boot/Image": Symlink("Image-6.12.47-v8"),       # fast, relative
        "/boot/abs": Symlink("/boot/Image"),              # absolute, 2 hops
        "/boot/up": Symlink("../boot/./Image-6.12.47-v8"),
        slow: blob[:5],
        "/boot/slow": Symlink(slow),                      # slow symlink
        "/boot/dangling": Symlink("Image-missing"),
        "/boot/loop1": Symlink("loop2"),
        "/boot/loop2": Symlink("loop1"),
        "/boot/dirlink": Symlink("/boot"),
        "/empty": b"",
    }
    tree = tmp_path / "t"
    tree.mkdir()
    write_tree(tree, files)
    fs = tmp_path / "fs.img"
    with open(fs, "wb") as f:
        f.truncate(8 * 1024 * 1024)
    subprocess.run(["mkfs.ext4", "-q", "-F", "-d", str(tree), str(fs)],
                   check=True, capture_output=True)
    part = Partition(1, "root_a", 0, fs.stat().st_size)

    assert ext4_read(fs, part, "/boot/Image-6.12.47-v8") == blob
    assert ext4_read(fs, part, "/boot/Image") == blob
    assert ext4_read(fs, part, "/boot/abs") == blob
    assert ext4_read(fs, part, "/boot/up") == blob
    assert ext4_read(fs, part, "/boot/slow") == blob[:5]
    assert ext4_read(fs, part, "/boot/dirlink/Image") == blob
    assert ext4_read(fs, part, "/empty") == b""
    assert ext4_read(fs, part, "/boot/nope") is None
    with pytest.raises(RuntimeError, match="dangling"):
        ext4_read(fs, part, "/boot/dangling")
    with pytest.raises(RuntimeError, match="hops"):
        ext4_read(fs, part, "/boot/loop1")
    with pytest.raises(RuntimeError, match="not a file"):
        ext4_read(fs, part, "/boot/dirlink")
