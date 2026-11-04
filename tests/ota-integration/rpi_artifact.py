"""Read-only access to the real raspberrypi4-64 build artifact (release gate).

The release workflow job `rpi-artifact-gate` downloads the build artifact
`yocto-image-raspberrypi4-64` (scripts/ydev/ci-collect-prod-artifacts.sh) and
points RPI_ARTIFACT_DIR at it; test_rpi_artifact.py then inspects the SAME wic
the release job publishes (`pick_wic` mirrors release.yml's pick order).

Nothing here mounts anything or needs root:
  - GPT parsed in Python (wks: firmware, uboot_env, uboot_envr, root_a,
    root_b, data — looked up by PARTLABEL, not by number)
  - FAT files via mtools (`mcopy -i img@@<offset>`)
  - ext4 files via debugfs (`debugfs -R "dump …" "img?offset=<offset>"`)
  - mkimage legacy script images unwrapped by `script_text`.
"""

from __future__ import annotations

import bz2
import gzip
import lzma
import os
import re
import shutil
import struct
import subprocess
import tempfile
import zlib
from dataclasses import dataclass
from pathlib import Path

_REPO = Path(__file__).resolve().parents[2]
BOOT_INC = _REPO / "meta-oe5xrx-remotestation" / "conf" / "oe5xrx-boot.inc"

REQUIRED_TOOLS = ("mcopy", "mdir", "debugfs", "fdtget", "fdtoverlay")

# --- mkimage legacy script image ---------------------------------------------

_IH_MAGIC = 0x27051956
_IH_TYPE_SCRIPT = 6
_IH_COMP_NONE = 0
_HDR = struct.Struct(">7I4B32s")  # 64 bytes, include/image.h legacy_hdr
assert _HDR.size == 64


def script_text(scr: bytes) -> str:
    """Script text of an `mkimage -T script -C none` image (boot.scr).

    Validates magic, header + data CRC, type=script and compression=none,
    then returns the first (only) sub-image of the multi-file payload
    (uint32-BE length table terminated by 0, then the data). ValueError on
    anything else — a gate must not silently read garbage."""
    if len(scr) < _HDR.size:
        raise ValueError("too short for a legacy image header")
    (magic, hcrc, _time, size, _load, _ep, dcrc, _os, _arch, itype, comp,
     _name) = _HDR.unpack_from(scr)
    if magic != _IH_MAGIC:
        raise ValueError(f"bad legacy image magic {magic:#x}")
    hdr = bytearray(scr[:_HDR.size])
    hdr[4:8] = b"\0\0\0\0"
    if zlib.crc32(hdr) != hcrc:
        raise ValueError("legacy image header CRC mismatch")
    if itype != _IH_TYPE_SCRIPT:
        raise ValueError(f"not a script image (type {itype})")
    if comp != _IH_COMP_NONE:
        raise ValueError(f"compressed script image (comp {comp})")
    payload = scr[_HDR.size:_HDR.size + size]
    if len(payload) != size:
        raise ValueError("truncated legacy image payload")
    if zlib.crc32(payload) != dcrc:
        raise ValueError("legacy image data CRC mismatch")
    lengths = []
    off = 0
    while True:
        if off + 4 > size:
            raise ValueError("unterminated script length table")
        (n,) = struct.unpack_from(">I", payload, off)
        off += 4
        if n == 0:
            break
        lengths.append(n)
    if not lengths or off + lengths[0] > size:
        raise ValueError("bad script length table")
    return payload[off:off + lengths[0]].decode()


# --- arm64 kernel Image header (booti) ----------------------------------------

_ARM64_MAGIC = 0x644D5241  # "ARM\x64", Linux Documentation/arm64/booting
_ARM64_HDR = struct.Struct("<IIQQQQQQII")  # code0 code1 text_offset image_size
assert _ARM64_HDR.size == 64               # flags res2-4 magic res5
_SZ_2M = 2 * 1024 * 1024


@dataclass(frozen=True)
class Arm64Image:
    text_offset: int
    image_size: int  # effective size incl. BSS (what booti memmoves)
    flags: int


def arm64_image_header(blob: bytes) -> Arm64Image:
    """Header fields of an arm64 Linux `Image`, as U-Boot booti_setup
    (arch/arm/lib/image.c) reads them. ValueError on a bad magic."""
    if len(blob) < _ARM64_HDR.size:
        raise ValueError("too short for an arm64 Image header")
    (_c0, _c1, text_offset, image_size, flags, _r2, _r3, _r4, magic,
     _r5) = _ARM64_HDR.unpack_from(blob)
    if magic != _ARM64_MAGIC:
        raise ValueError(f"bad arm64 Image magic {magic:#x}")
    if image_size == 0:  # pre-3.17 kernel: booti assumes these
        return Arm64Image(0x80000, 16 << 20, flags)
    return Arm64Image(text_offset, image_size, flags)


def booti_relocated_addr(load: int, img: Arm64Image, dram_base: int = 0) -> int:
    """Where booti moves the Image to (booti_setup, force_reloc=false)."""
    dst = load - img.text_offset if img.flags & (1 << 3) else dram_base
    return (dst + _SZ_2M - 1) // _SZ_2M * _SZ_2M + img.text_offset


# --- artifact discovery -------------------------------------------------------

# Same order as release.yml `pick_wic`: the gate checks exactly the file the
# release job publishes.
_WIC_EXTS = ("wic.bz2", "wic.xz", "wic.gz", "wic")


def pick_wic(artifact_dir: Path) -> Path:
    for ext in _WIC_EXTS:
        matches = sorted(Path(artifact_dir).glob(f"*.{ext}"))
        if matches:
            return matches[0]
    raise FileNotFoundError(f"no *.wic[.bz2|.xz|.gz] in {artifact_dir}")


_CHUNK = 1024 * 1024
_ZERO = bytes(_CHUNK)


def materialize_wic(src: Path, dest_dir: Path) -> Path:
    """Path to a raw wic: `src` itself, or a SPARSE decompressed copy in
    `dest_dir` (the ~3.2 GiB image is mostly zeros)."""
    opener = {".bz2": bz2.open, ".xz": lzma.open, ".gz": gzip.open}.get(
        src.suffix)
    if opener is None:
        return src
    out = Path(dest_dir) / src.with_suffix("").name
    total = 0
    with opener(src, "rb") as fin, open(out, "wb") as fout:
        while True:
            chunk = fin.read(_CHUNK)
            if not chunk:
                break
            total += len(chunk)
            if chunk == _ZERO[:len(chunk)]:
                fout.seek(len(chunk), os.SEEK_CUR)
            else:
                fout.write(chunk)
        fout.truncate(total)
    return out


def release_overlays(boot_inc: Path = BOOT_INC) -> list[str]:
    """The release overlay list: the OE5XRX_DT_OVERLAYS default in
    conf/oe5xrx-boot.inc (a release build never adds test overlays)."""
    m = re.search(r'^OE5XRX_DT_OVERLAYS \?\?= "([^"]*)"', boot_inc.read_text(),
                  re.M)
    if m is None:
        raise ValueError(f"no OE5XRX_DT_OVERLAYS default in {boot_inc}")
    return m.group(1).split()


# --- GPT ----------------------------------------------------------------------

_SECTOR = 512


@dataclass(frozen=True)
class Partition:
    number: int
    label: str
    offset: int  # bytes
    size: int    # bytes


def read_gpt(img: Path) -> dict[str, Partition]:
    """PARTLABEL -> Partition from the primary GPT (512-byte sectors, wic)."""
    with open(img, "rb") as f:
        f.seek(_SECTOR)
        hdr = f.read(92)
        if hdr[:8] != b"EFI PART":
            raise ValueError(f"{img}: no primary GPT header")
        entries_lba, count, esize = struct.unpack_from("<QII", hdr, 72)
        f.seek(entries_lba * _SECTOR)
        table = f.read(count * esize)
    parts: dict[str, Partition] = {}
    for i in range(count):
        e = table[i * esize:(i + 1) * esize]
        if e[:16] == bytes(16):
            continue
        first, last = struct.unpack_from("<QQ", e, 32)
        label = e[56:128].decode("utf-16-le").rstrip("\0")
        if label in parts:
            raise ValueError(f"{img}: duplicate PARTLABEL {label!r}")
        parts[label] = Partition(i + 1, label, first * _SECTOR,
                                 (last - first + 1) * _SECTOR)
    return parts


# --- FAT (mtools) / ext4 (debugfs) --------------------------------------------

def _mtools_env() -> dict[str, str]:
    return {**os.environ, "MTOOLS_SKIP_CHECK": "1"}


def fat_list(img: Path, part: Partition) -> list[str]:
    """All file paths on the FAT partition, '/'-rooted (e.g. /overlays/x)."""
    r = subprocess.run(["mdir", "-/", "-b", "-i", f"{img}@@{part.offset}",
                        "::/"], capture_output=True, text=True,
                       env=_mtools_env(), timeout=60)
    if r.returncode != 0:
        raise RuntimeError(f"mdir failed: {r.stderr}")
    out = []
    for line in r.stdout.splitlines():
        line = line.strip()
        if line.startswith("::"):
            p = line[2:]
            if p and not p.endswith("/"):
                out.append(p if p.startswith("/") else "/" + p)
    return out


def fat_read(img: Path, part: Partition, path: str) -> bytes | None:
    """File content from the FAT partition, None if absent."""
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "f"
        r = subprocess.run(["mcopy", "-n", "-i", f"{img}@@{part.offset}",
                            f"::{path}", str(out)], capture_output=True,
                           text=True, env=_mtools_env(), timeout=60)
        if r.returncode != 0 or not out.exists():
            return None
        return out.read_bytes()


def _debugfs(img: Path, part: Partition, cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(["debugfs", "-R", cmd, f"{img}?offset={part.offset}"],
                          capture_output=True, text=True, timeout=120)


def ext4_list(img: Path, part: Partition, directory: str) -> list[str] | None:
    """Entry names in an ext4 directory (no . / ..), None if absent."""
    r = _debugfs(img, part, f"ls -p {directory}")
    if r.returncode != 0 or "not found" in r.stderr or "Bad magic" in r.stderr:
        return None
    names = []
    for line in r.stdout.splitlines():
        # /inode/mode/uid/gid/name/size/
        fields = line.split("/")
        if len(fields) >= 7 and fields[5] not in (".", ".."):
            names.append(fields[5])
    return names


def ext4_read(img: Path, part: Partition, path: str) -> bytes | None:
    """Regular-file content from an ext4 partition, None if absent."""
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "f"
        r = _debugfs(img, part, f"dump {path} {out}")
        if r.returncode != 0 or not out.exists():
            return None
        return out.read_bytes()


def missing_tools() -> list[str]:
    return [t for t in REQUIRED_TOOLS if shutil.which(t) is None]
