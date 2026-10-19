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

def test_harness_runs_sim_in_persistent_state_dir():
    """FW schema 2 persists the synthetic UID in the sim's CWD; that must be on /var."""
    sh = _read(os.path.join(_LAYER, "recipes-core", "oe5xrx-sim-harness", "files",
                            "sim-harness.sh"))
    assert 'SIM_STATE_DIR="${SIM_STATE_DIR:-/var/lib/oe5xrx/sim}"' in sh
    assert 'cd "$SIM_STATE_DIR"' in sh


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
    fetch = [ln for ln in bb.splitlines() if "${FW_RELEASE_TAG}/" in ln]
    assert fetch, "no release-asset SRC_URI line"
    for ln in fetch:
        assert "${FW_RELEASE_TAG}/${FW_FM_ASSET}." in ln, ln


def test_fm_firmware_installs_stable_name():
    """On-target path must not move when FW_FM_ASSET flips 2m -> vhf."""
    bb = _read(os.path.join(_LAYER, "recipes-core", "oe5xrx-fm-firmware",
                            "oe5xrx-fm-firmware.bb"))
    assert "${D}${nonarch_base_libdir}/firmware/oe5xrx/fm-sa818-vhf.bin" in bb
    assert 'FILES:${PN} = "${nonarch_base_libdir}/firmware/oe5xrx/fm-sa818-vhf.bin"' in bb


def test_harness_ignores_group_writable_override(sim_dirs):
    tmp_path, override = sim_dirs
    _fake_sim(override, tmp_path / "override-ran", mode=0o775)
    res = _run_harness(tmp_path, override)
    assert "ignoring unsafe override" in res.stderr
    assert f"using native_sim {tmp_path / 'image-bin'}" in res.stderr
    assert not (tmp_path / "override-ran").exists()


# ---- bump-fw-release.sh FW_FM_ASSET detection (hermetic) -------------------------

_FW_FILES = [
    ("scripts", "bump-fw-release.sh"),
    ("meta-oe5xrx-remotestation", "conf", "oe5xrx-fw-release.inc"),
    ("meta-oe5xrx-remotestation", "recipes-core", "oe5xrx-fm-firmware",
     "oe5xrx-fm-firmware.bb"),
    ("meta-oe5xrx-remotestation", "recipes-core", "oe5xrx-native-sim-fm",
     "oe5xrx-native-sim-fm.bb"),
    ("meta-oe5xrx-remotestation", "recipes-core", "oe5xrx-sim-harness",
     "oe5xrx-sim-harness_1.0.bb"),
]

# curl stub: serves `-o <file> <url>` from $FAKE_RELEASE/<basename(url)>; 22 if absent.
_CURL_STUB = """#!/bin/sh
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
src="$FAKE_RELEASE/${url##*/}"
[ -f "$src" ] || exit 22
cp "$src" "$out"
"""


@pytest.fixture
def fw_tree(tmp_path):
    import shutil
    root = tmp_path / "repo"
    for parts in _FW_FILES:
        dst = root.joinpath(*parts)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(os.path.join(_REPO, *parts), dst)
    stubs = tmp_path / "bin"
    stubs.mkdir()
    (stubs / "curl").write_text(_CURL_STUB)
    (stubs / "cosign").write_text("#!/bin/sh\nexit 0\n")  # authenticity is not under test
    for s in ("curl", "cosign"):
        os.chmod(stubs / s, 0o755)
    release = tmp_path / "release"
    release.mkdir()
    return root, stubs, release


def _publish(release, prefixes):
    import hashlib
    sums = []
    for pfx in prefixes:
        for ext in (".bin", ".native_sim", ".sa818-sim.py"):
            name = pfx + ext
            data = f"{name}\n".encode()
            (release / name).write_bytes(data)
            (release / (name + ".bundle")).write_text("{}")
            sums.append(f"{hashlib.sha256(data).hexdigest()}  {name}")
    (release / "SHA256SUMS").write_text("\n".join(sums) + "\n")


def _bump(fw_tree, *args):
    root, stubs, release = fw_tree
    env = dict(os.environ, PATH=f"{stubs}:{os.environ['PATH']}",
               FAKE_RELEASE=str(release))
    return subprocess.run(["bash", str(root / "scripts" / "bump-fw-release.sh"), *args],
                          env=env, capture_output=True, text=True, timeout=60)


def _inc_var(root, var):
    inc = (root / "meta-oe5xrx-remotestation" / "conf" / "oe5xrx-fw-release.inc").read_text()
    return re.search(rf'^{var} \?= "([^"]*)"$', inc, re.M).group(1)


@pytest.mark.parametrize("published,expected", [
    (["fm-sa818-vhf", "fm-sa818-uhf"], "fm-sa818-vhf"),
    (["fm-sa818-2m", "fm-sa818-70cm"], "fm-sa818-2m"),
    (["fm-sa818-2m", "fm-sa818-vhf"], "fm-sa818-vhf"),
])
def test_bump_detects_fm_asset(fw_tree, published, expected):
    root, _, release = fw_tree
    _publish(release, published)
    res = _bump(fw_tree, "99.01.01-01")
    assert res.returncode == 0, res.stderr
    assert _inc_var(root, "FW_RELEASE_TAG") == "99.01.01-01"
    assert _inc_var(root, "FW_FM_ASSET") == expected
    check = _bump(fw_tree, "--check")
    assert check.returncode == 0, check.stderr


def test_bump_fails_untouched_without_fm_asset(fw_tree):
    root, _, release = fw_tree
    _publish(release, ["fm-sa818-70cm"])
    before = {p: root.joinpath(*p).read_bytes() for p in _FW_FILES}
    res = _bump(fw_tree, "99.01.01-01")
    assert res.returncode != 0
    assert "no FM asset" in res.stderr
    assert {p: root.joinpath(*p).read_bytes() for p in _FW_FILES} == before
