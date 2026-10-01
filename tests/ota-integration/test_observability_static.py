"""Static guards for the debug-observability OS enablement (spec
2026-10-01-image-debug-observability-design.md). Pure file-content checks —
run on every PR via `-m unit`; no build/qemu needed."""

import os

import pytest

pytestmark = pytest.mark.unit

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_LAYER = os.path.join(_REPO, "meta-oe5xrx-remotestation")


def _read(*parts):
    with open(os.path.join(_REPO, *parts)) as f:
        return f.read()


# ---- Task 1: pstore kernel fragment -------------------------------------

_PSTORE_CFG = ("meta-oe5xrx-remotestation", "recipes-kernel", "linux",
               "files", "oe5xrx-pstore.cfg")


def test_pstore_fragment_enables_ram_backend():
    cfg = _read(*_PSTORE_CFG)
    for sym in ("CONFIG_PSTORE=y", "CONFIG_PSTORE_RAM=y",
                "CONFIG_PSTORE_CONSOLE=y", "CONFIG_PSTORE_PMSG=y"):
        assert sym in cfg, f"{sym} missing from oe5xrx-pstore.cfg"


@pytest.mark.parametrize("bbappend", [
    "linux-raspberrypi_%.bbappend",
    "linux-yocto_%.bbappend",
])
def test_pstore_fragment_wired_into_both_kernels(bbappend):
    txt = _read("meta-oe5xrx-remotestation", "recipes-kernel", "linux", bbappend)
    assert "oe5xrx-pstore.cfg" in txt, (
        f"{bbappend} does not SRC_URI:append file://oe5xrx-pstore.cfg"
    )


# ---- Task 2: ramoops cmdline in both bootloaders ------------------------

_RAMOOPS_TOKENS = [
    "reserve_mem=2M:4096:oops",
    "ramoops.mem_name=oops",
    "ramoops.ecc=1",
    "ramoops.record_size=0x40000",
    "ramoops.console_size=0x40000",
    "ramoops.pmsg_size=0x40000",
]

_BOOTLOADERS = [
    ("meta-oe5xrx-remotestation", "recipes-bsp", "u-boot-ab", "files", "boot.cmd"),
    ("meta-oe5xrx-remotestation", "files", "wic", "oe5xrx-grub.cfg"),
    ("meta-oe5xrx-remotestation", "recipes-bsp", "grub-ab", "files", "grub.cfg"),
]


@pytest.mark.parametrize("path", _BOOTLOADERS, ids=lambda p: p[-1] + ":" + p[-2])
def test_ramoops_cmdline_present_in_every_bootloader(path):
    txt = _read(*path)
    for tok in _RAMOOPS_TOKENS:
        assert tok in txt, f"{'/'.join(path)} missing ramoops token {tok!r}"
