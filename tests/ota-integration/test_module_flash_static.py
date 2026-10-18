"""Guards for the module-firmware flash image half (Teil D): dfu-util in the
image, the sim-harness native_sim override, the slot->USB-port map and the
FW_FM_ASSET indirection. File-content checks plus a host run of the real
sim-harness.sh binary selection — run on every PR via `-m unit`."""

import os
import re
import stat
import subprocess

import pytest

pytestmark = pytest.mark.unit

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_LAYER = os.path.join(_REPO, "meta-oe5xrx-remotestation")
_HARNESS = os.path.join(_LAYER, "recipes-core", "oe5xrx-sim-harness", "files",
                        "sim-harness.sh")
_SLOT_UDEV = os.path.join(_LAYER, "recipes-core", "oe5xrx-slot-udev")


def _read(path):
    with open(path) as f:
        return f.read()


# ---- dfu-util ----------------------------------------------------------------

def test_dfu_util_in_base_image_for_all_machines():
    bb = _read(os.path.join(_LAYER, "recipes-core", "images",
                            "oe5xrx-remotestation-image.bb"))
    # Unconditional append (no :<machine> override) -> rpi64 AND qemux86-64.
    assert re.search(r'^IMAGE_INSTALL:append = "[^"]*\bdfu-util\b', bb, re.M), (
        "dfu-util must be appended to IMAGE_INSTALL for all machines"
    )


# ---- slot -> USB port map ------------------------------------------------------

def _slots_conf():
    out = {}
    for line in _read(os.path.join(_SLOT_UDEV, "files", "slots.conf")).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, val = line.partition("=")
        out[key] = val
    return out


def test_slots_conf_well_formed():
    slots = _slots_conf()
    assert slots, "slots.conf is empty"
    for key, val in slots.items():
        assert re.fullmatch(r"slot[1-9][0-9]*", key), key
        assert re.fullmatch(r"[0-9]+-[0-9]+(\.[0-9]+)*", val), (key, val)


def test_slots_conf_matches_udev_rules():
    """slots.conf is the single source of truth; the udev rules hardcode the same
    mapping per line and must not drift from it (control + audio halves)."""
    rules = _read(os.path.join(_SLOT_UDEV, "files", "90-oe5xrx-slots.rules"))
    control = dict(
        (f"slot{n}", port) for port, n in re.findall(
            r'KERNELS=="([^"]+)", SYMLINK\+="oe5xrx/slot([0-9]+)/control"', rules)
    )
    audio = dict(
        (f"slot{n}", port) for port, n in re.findall(
            r'KERNELS=="([^"]+)", ENV\{OE5XRX_SLOT\}="([0-9]+)"', rules)
    )
    slots = _slots_conf()
    assert control == slots
    assert audio == slots


def test_slots_conf_installed_by_slot_udev_recipe():
    bb = _read(os.path.join(_SLOT_UDEV, "oe5xrx-slot-udev_1.0.bb"))
    assert "file://slots.conf" in bb
    assert "${sysconfdir}/oe5xrx/slots.conf" in bb


# ---- native_sim override dir ---------------------------------------------------

def test_data_init_creates_root_owned_sim_dir():
    sh = _read(os.path.join(_LAYER, "recipes-core", "ab-layout", "files",
                            "data-init.sh"))
    assert 'mkdir -p "${DATA}/var/lib/oe5xrx/sim"' in sh
    assert re.search(r'chown 0:0 [^\n]*"\$\{DATA\}/var/lib/oe5xrx/sim"', sh)
    assert re.search(r'chmod 0755 [^\n]*"\$\{DATA\}/var/lib/oe5xrx/sim"', sh)


def test_harness_default_override_path():
    assert ('SIM_OVERRIDE="${SIM_OVERRIDE:-/var/lib/oe5xrx/sim/native-sim-fm}"'
            in _read(_HARNESS))


def _fake_sim(path, marker, mode=0o755):
    # Stand-in native_sim: records that it ran and announces a bogus radio pty
    # -> the harness bails out ("no SA818 pty") right after binary selection.
    with open(path, "w") as f:
        f.write(f"#!/bin/sh\necho ran > '{marker}'\n"
                "echo 'uart_1 connected to pseudotty: /nonexistent/pty'\n")
    os.chmod(path, mode)


def _run_harness(tmp_path, override):
    env = {k: v for k, v in os.environ.items() if k != "SIM_BIN"}
    env.update(
        SIM_IMAGE_BIN=str(tmp_path / "image-bin"),
        SIM_OVERRIDE=str(override),
        SA818_SIM=str(tmp_path / "no-sa818.py"),
        SLOT_DIR=str(tmp_path / "slot1"),
        RUNDIR=str(tmp_path / "run"),
    )
    return subprocess.run(["sh", _HARNESS], env=env, capture_output=True,
                          text=True, timeout=30)


@pytest.fixture
def sim_dirs(tmp_path):
    _fake_sim(tmp_path / "image-bin", tmp_path / "image-ran")
    override_dir = tmp_path / "var-lib-sim"
    override_dir.mkdir()
    return tmp_path, override_dir / "native-sim-fm"


def test_harness_prefers_executable_override(sim_dirs):
    tmp_path, override = sim_dirs
    _fake_sim(override, tmp_path / "override-ran")
    res = _run_harness(tmp_path, override)
    assert f"using native_sim {override}" in res.stderr
    assert (tmp_path / "override-ran").exists()
    assert not (tmp_path / "image-ran").exists()


def test_harness_falls_back_when_override_absent(sim_dirs):
    tmp_path, override = sim_dirs
    res = _run_harness(tmp_path, override)
    assert f"using native_sim {tmp_path / 'image-bin'}" in res.stderr
    assert (tmp_path / "image-ran").exists()


def test_harness_ignores_non_executable_override(sim_dirs):
    tmp_path, override = sim_dirs
    _fake_sim(override, tmp_path / "override-ran", mode=0o644)
    res = _run_harness(tmp_path, override)
    assert f"using native_sim {tmp_path / 'image-bin'}" in res.stderr
    assert not (tmp_path / "override-ran").exists()


def test_harness_ignores_symlinked_override(sim_dirs):
    tmp_path, override = sim_dirs
    target = tmp_path / "elsewhere"
    _fake_sim(target, tmp_path / "override-ran")
    os.symlink(target, override)
    assert stat.S_ISLNK(os.lstat(override).st_mode)
    res = _run_harness(tmp_path, override)
    assert f"using native_sim {tmp_path / 'image-bin'}" in res.stderr
    assert not (tmp_path / "override-ran").exists()


# ---- FW_FM_ASSET indirection ---------------------------------------------------

def test_fw_fm_asset_defined_in_include():
    inc = _read(os.path.join(_LAYER, "conf", "oe5xrx-fw-release.inc"))
    assert re.search(r'^FW_FM_ASSET \?= "fm-sa818-(2m|vhf)"$', inc, re.M)


@pytest.mark.parametrize("recipe", [
    ("oe5xrx-fm-firmware", "oe5xrx-fm-firmware.bb"),
    ("oe5xrx-native-sim-fm", "oe5xrx-native-sim-fm.bb"),
    ("oe5xrx-sim-harness", "oe5xrx-sim-harness_1.0.bb"),
])
def test_fw_recipes_use_asset_variable(recipe):
    """The asset basename lives only in the include, so the 2m->vhf rename is a
    pure bump-fw-release.sh run (no recipe edit)."""
    bb = _read(os.path.join(_LAYER, "recipes-core", *recipe))
    assert "${FW_FM_ASSET}" in bb
    assert "fm-sa818-2m" not in bb and "fm-sa818-vhf" not in bb
