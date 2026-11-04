"""Read-only access to the real raspberrypi4-64 build artifact (release gate).

The release workflow job `rpi-artifact-gate` downloads the build artifact
`yocto-image-raspberrypi4-64` (scripts/ydev/ci-collect-prod-artifacts.sh) and
points RPI_ARTIFACT_DIR at it; test_rpi_artifact.py then inspects the SAME wic
the release job publishes (`pick_wic` mirrors release.yml's pick order).

Nothing here mounts anything or needs root:
  - GPT parsed in Python (wks: firmware, uboot_env, uboot_envr, root_a,
    root_b, data — looked up by PARTLABEL, not by number)
  - FAT files via mtools (`mcopy -i img@@<offset>`)
  - ext4 files via debugfs (`debugfs -R "dump …" "img?offset=<offset>"`),
    symlinks resolved via `stat` (debugfs dump does not follow them)
  - mkimage legacy script images unwrapped by `script_text`.
"""

from __future__ import annotations

import bz2
import gzip
import lzma
import os
import posixpath
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


# Parallel bzip2 decompressors (output identical to bzip2/Python bz2, incl.
# multi-stream files); single-threaded bz2 takes minutes on the ~3.2 GiB wic.
_PARALLEL_BZ2 = ("lbzip2", "pbzip2")


def parallel_bz2_tool() -> str | None:
    """First parallel bzip2 decompressor on PATH, or None."""
    for tool in _PARALLEL_BZ2:
        path = shutil.which(tool)
        if path is not None:
            return path
    return None


def _sparse_copy(fin, fout) -> None:
    """Copy `fin` to `fout`, seeking over all-zero chunks (sparse output)."""
    total = 0
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


def materialize_wic(src: Path, dest_dir: Path,
                    bz2_tool: str | None = None) -> Path:
    """Path to a raw wic: `src` itself, or a SPARSE decompressed copy in
    `dest_dir` (the ~3.2 GiB image is mostly zeros).

    .bz2 goes through `lbzip2 -dc`/`pbzip2 -dc` when one is on PATH (or
    `bz2_tool` is given), else Python's bz2. A failing tool raises — a gate
    must not inspect a truncated image."""
    opener = {".bz2": bz2.open, ".xz": lzma.open, ".gz": gzip.open}.get(
        src.suffix)
    if opener is None:
        return src
    out = Path(dest_dir) / src.with_suffix("").name
    tool = None
    if src.suffix == ".bz2":
        tool = bz2_tool or parallel_bz2_tool()
    if tool is not None:
        # stderr to a file, not a pipe: nobody drains it while we read stdout.
        with tempfile.TemporaryFile() as errf, \
                open(out, "wb") as fout, \
                subprocess.Popen([tool, "-dc", str(src)],
                                 stdout=subprocess.PIPE, stderr=errf) as proc:
            _sparse_copy(proc.stdout, fout)
            proc.wait()
            errf.seek(0)
            err = errf.read().decode(errors="replace").strip()
        if proc.returncode != 0:
            raise RuntimeError(
                f"{tool} -dc {src} failed (rc {proc.returncode}): {err}")
        return out
    with opener(src, "rb") as fin, open(out, "wb") as fout:
        _sparse_copy(fin, fout)
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


def _debugfs_raw(img: Path, part: Partition,
                 cmd: str) -> tuple[int, bytes, str]:
    """(returncode, stdout bytes, stderr minus the version banner)."""
    r = subprocess.run(["debugfs", "-R", cmd, f"{img}?offset={part.offset}"],
                       capture_output=True, timeout=120)
    err = "\n".join(
        line for line in r.stderr.decode(errors="replace").splitlines()
        if line.strip() and not _DEBUGFS_BANNER.match(line))
    return r.returncode, r.stdout, err


# debugfs prints "debugfs 1.47.2 (1-Jan-2025)" on stderr for every command;
# anything else on stderr is an error (debugfs itself exits 0 regardless).
_DEBUGFS_BANNER = re.compile(r"^debugfs \d+\.\d+")
_NOT_FOUND = "File not found by ext2_lookup"
# Max symlink hops (Linux follows 40; a release rootfs needs 1).
EXT4_MAX_LINK_HOPS = 8


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


@dataclass(frozen=True)
class Ext4Inode:
    ino: int
    type: str   # debugfs "Type:": regular, directory, symlink, ...
    size: int   # i_size (for a symlink: length of the target)
    fast_link: bytes | None  # target of a fast (inline) symlink


def ext4_stat(img: Path, part: Partition, path: str) -> Ext4Inode | None:
    """Inode of `path` WITHOUT following a final symlink; None if absent.
    RuntimeError on any other debugfs error (bad fs, unparsable output)."""
    rc, out, err = _debugfs_raw(img, part, f"stat {path}")
    if _NOT_FOUND in err:
        return None
    if rc != 0 or err:
        raise RuntimeError(f"debugfs stat {path} failed (rc {rc}): {err}")
    m = re.search(rb"^Inode: (\d+)\s+Type: (\S+)", out, re.M)
    sz = re.search(rb"^User:.*\bSize: (\d+)", out, re.M)
    if m is None or sz is None:
        raise RuntimeError(f"debugfs stat {path}: unparsable output:\n"
                           f"{out.decode(errors='replace')}")
    size = int(sz.group(1))
    fast = None
    tag = b'Fast link dest: "'
    i = out.find(b"\n" + tag)
    if i >= 0:
        # Raw target bytes, exactly i_size of them, then the closing quote.
        start = i + 1 + len(tag)
        fast = out[start:start + size]
        if out[start + size:start + size + 1] != b'"':
            raise RuntimeError(f"debugfs stat {path}: fast link dest does "
                               f"not match i_size {size}")
    return Ext4Inode(int(m.group(1)), m.group(2).decode(), size, fast)


def _ext4_link_target(img: Path, part: Partition, path: str,
                      st: Ext4Inode) -> str:
    """Target of the symlink `path` (fast: inline in the inode, else the
    data block via `cat <ino>`). Length must equal i_size."""
    if st.fast_link is not None:
        target = st.fast_link
    else:
        rc, target, err = _debugfs_raw(img, part, f"cat <{st.ino}>")
        if rc != 0 or err:
            raise RuntimeError(
                f"debugfs cat of symlink {path} failed (rc {rc}): {err}")
    if len(target) != st.size or not target:
        raise RuntimeError(f"symlink {path}: read {len(target)} target "
                           f"bytes, inode says {st.size}")
    return target.decode()


def ext4_resolve(img: Path, part: Partition,
                 path: str) -> tuple[str, Ext4Inode] | None:
    """Follow `path` through symlinks (relative targets against the link's
    directory, at most EXT4_MAX_LINK_HOPS) to its final inode. None if
    `path` itself is absent; RuntimeError on a dangling link or a loop.
    Symlinked intermediate directories are followed by debugfs (namei)."""
    cur = path
    for _hop in range(EXT4_MAX_LINK_HOPS + 1):
        st = ext4_stat(img, part, cur)
        if st is None:
            if cur == path:
                return None
            raise RuntimeError(f"dangling symlink: {path} -> {cur} "
                               "does not exist")
        if st.type != "symlink":
            return cur, st
        target = _ext4_link_target(img, part, cur, st)
        base = "/" if target.startswith("/") else posixpath.dirname(cur)
        cur = "/" + posixpath.normpath(
            posixpath.join(base, target)).lstrip("/")
    raise RuntimeError(f"{path}: more than {EXT4_MAX_LINK_HOPS} symlink hops")


def ext4_read(img: Path, part: Partition, path: str) -> bytes | None:
    """Content of the regular file at `path` on an ext4 partition, following
    symlinks (the rootfs /boot/Image is one: OE-core
    KERNEL_IMAGETYPE_SYMLINK -> Image-<KERNEL_VERSION>). None if `path` is
    absent. RuntimeError on a dangling link, a non-regular target, any
    debugfs error or a short read (`debugfs dump` of a symlink silently
    writes 0 bytes with exit 0 — never trust its exit code alone)."""
    res = ext4_resolve(img, part, path)
    if res is None:
        return None
    real, st = res
    if st.type != "regular":
        raise RuntimeError(f"{path} -> {real} is a {st.type}, not a file")
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "f"
        rc, _, err = _debugfs_raw(img, part, f"dump <{st.ino}> {out}")
        if rc != 0 or err or not out.exists():
            raise RuntimeError(
                f"debugfs dump {path} ({real}) failed (rc {rc}): {err}")
        blob = out.read_bytes()
    if len(blob) != st.size:
        raise RuntimeError(f"{path} ({real}): read {len(blob)} bytes, "
                           f"inode size {st.size}")
    return blob


def missing_tools() -> list[str]:
    return [t for t in REQUIRED_TOOLS if shutil.which(t) is None]
