"""Image manipulation helpers for the OTA integration test.

Pure helpers (sha256, bz2, decompress) are unit-tested. The partition-extraction
and loop-mount helpers require root + losetup and are exercised by the
qemu-marked flow in CI.

The OTA payload the agent expects is the **rootfs ext4** (partition 2 = root_a
in the A/B wic layout) bz2-compressed — this mirrors what station-manager
extracts and serves at ImageRelease import time. Partition order in
oe5xrx-remotestation-ab-x64.wks.in: 1=efi, 2=root_a, 3=root_b, 4=data.
"""

from __future__ import annotations

import bz2
import hashlib
import os
import shutil
import subprocess
import time
from contextlib import contextmanager

ROOT_A_PARTNUM = 2  # 1=efi 2=root_a 3=root_b 4=data
DATA_PARTNUM = 4
EFI_PARTNUM = 1

_CHUNK = 1024 * 1024


def sha256_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(_CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def bz2_compress(src: str, dst: str) -> None:
    with open(src, "rb") as fin, bz2.open(dst, "wb") as fout:
        for chunk in iter(lambda: fin.read(_CHUNK), b""):
            fout.write(chunk)


def decompress_wic(src: str, out_wic: str) -> str:
    """Return a path to a decompressed .wic. Handles the compression formats
    release.yml may publish (.wic.bz2 / .wic.xz / .wic.gz); a plain .wic is
    copied verbatim (qemu -drive needs a raw, uncompressed image)."""
    if src.endswith(".bz2"):
        opener = bz2.open
    elif src.endswith(".xz"):
        import lzma
        opener = lzma.open
    elif src.endswith(".gz"):
        import gzip
        opener = gzip.open
    else:
        shutil.copyfile(src, out_wic)
        return out_wic
    with opener(src, "rb") as fin, open(out_wic, "wb") as fout:
        for chunk in iter(lambda: fin.read(_CHUNK), b""):
            fout.write(chunk)
    return out_wic


def _wait_for_partition_nodes(dev: str, timeout: float = 15.0) -> None:
    """Block until every partition of loop device `dev` has its /dev/<dev>pN node.

    `losetup --partscan` makes the kernel scan the partition table synchronously
    (the partitions appear under /sys/block/<dev>/ before losetup returns), but the
    matching /dev/<dev>pN nodes are created *asynchronously* by udev in response to
    the uevents. A consumer that touches /dev/<dev>pN immediately therefore races
    that node creation and intermittently fails with "mount: ... No such file or
    directory" (exit 32). Wait it out: settle udev, then poll the sysfs-listed
    partitions until all their device nodes exist. sysfs is the synchronous source
    of truth for *which* partitions exist, so this is layout-agnostic.
    """
    base = os.path.basename(dev)
    sysdir = f"/sys/block/{base}"
    subprocess.run(["udevadm", "settle"], check=False)  # best-effort; may be absent
    deadline = time.monotonic() + timeout
    while True:
        try:
            parts = [p for p in os.listdir(sysdir) if p.startswith(base + "p")]
        except OSError:
            parts = []
        if parts and all(os.path.exists(f"/dev/{p}") for p in parts):
            return
        if time.monotonic() >= deadline:
            missing = [f"/dev/{p}" for p in parts if not os.path.exists(f"/dev/{p}")]
            raise RuntimeError(
                f"partition nodes for {dev} did not appear within {timeout}s "
                f"(sysfs partitions={parts or 'none yet'}, missing nodes={missing or 'n/a'})"
            )
        time.sleep(0.1)


@contextmanager
def loop_attach(wic_path: str):
    """Attach wic_path as a partition-scanned loop device; yield e.g. /dev/loop3.
    Always detaches. Requires root."""
    dev = subprocess.run(
        ["losetup", "--find", "--show", "--partscan", wic_path],
        check=True, capture_output=True, text=True,
    ).stdout.strip()
    try:
        _wait_for_partition_nodes(dev)  # avoid racing async udev node creation
        yield dev
    finally:
        subprocess.run(["losetup", "-d", dev], check=False)


def extract_rootfs_bz2(wic_path: str, out_bz2: str) -> tuple[str, int]:
    """Extract partition ROOT_A_PARTNUM (the ext4 rootfs) from wic_path,
    bz2-compress it to out_bz2, and return (sha256_hex, size_bytes) of the
    COMPRESSED file. Requires root."""
    with loop_attach(wic_path) as dev:
        part = f"{dev}p{ROOT_A_PARTNUM}"
        with open(part, "rb") as fin, bz2.open(out_bz2, "wb") as fout:
            for chunk in iter(lambda: fin.read(_CHUNK), b""):
                fout.write(chunk)
    return sha256_file(out_bz2), _filesize(out_bz2)


def _filesize(path: str) -> int:
    import os
    return os.path.getsize(path)
