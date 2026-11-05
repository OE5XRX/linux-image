"""Static guards for the two-stage CM4 boot RECIPES (spec
docs/superpowers/specs/2026-11-04-slot-boot-stage2-overlays-design.md §2–§4, §7):

- u-boot-ab renders boot-stage2.cmd.in with sed and installs the compiled
  stage 2 into the ROOTFS (/boot/boot-stage2.scr) — the sed rendering must be
  byte-identical to boot_scripts.render_stage2 (proven here by running the
  recipe's own sed expressions against the inc's own overlay-list logic).
- conf/oe5xrx-boot.inc is the single source of the effective overlay list and
  of the OE5XRX_BOOT_TEST fault switch (never allowed in release builds).
- oe5xrx-dt-overlays installs every listed overlay to /boot/overlays/ in the
  rootfs (no more FAT/config.txt route).
- U-Boot gets the fdt-overlay Kconfig fragment + a bbfatal guard.

Pure file-content checks (+ sed/dtc when installed) — run on every PR via
`-m unit`; no Yocto build needed."""

import os
import re
import shutil
import subprocess

import pytest
import yaml
from boot_scripts import (
    PH_OVERLAYS,
    PH_OVERLAYS_BOOTARG,
    PH_OVERLAYS_CSV,
    read_stage2_template,
    render_stage2,
)

pytestmark = pytest.mark.unit

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_LAYER = "meta-oe5xrx-remotestation"
_BSP = (_LAYER, "recipes-bsp")
_INC = (_LAYER, "conf", "oe5xrx-boot.inc")
_UBOOT_AB = _BSP + ("u-boot-ab", "u-boot-ab_1.0.bb")
_UBOOT_AB_FILES = _BSP + ("u-boot-ab", "files")
_UBOOT_APPEND = _BSP + ("u-boot", "u-boot_%.bbappend")
_UBOOT_FILES = _BSP + ("u-boot", "files")
_OVL_RECIPE = _BSP + ("oe5xrx-dt-overlays", "oe5xrx-dt-overlays_1.0.bb")
_OVL_FILES = _BSP + ("oe5xrx-dt-overlays", "files")
_IMAGE = (_LAYER, "recipes-core", "images", "oe5xrx-remotestation-image.bb")

_TEST_YMLS = {
    "include/boot-test-marker.yml": "marker",
    "include/boot-test-stage2-broken.yml": "stage2-broken",
    "include/boot-test-overlay-broken.yml": "overlay-broken",
}


def _path(*parts):
    return os.path.join(_REPO, *parts)


def _read(*parts):
    with open(_path(*parts)) as f:
        return f.read()


def _code_lines(txt):
    """Non-comment, non-blank lines (BitBake/kas comments start with #)."""
    return [ln for ln in txt.splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")]


def _shell_func(bb_text, name):
    """Body of a BitBake shell function `name() { ... }` (closing `}` at col 0)."""
    m = re.search(r"^" + re.escape(name) + r"\(\) \{\n(.*?)^\}", bb_text,
                  re.M | re.S)
    assert m, f"{name}() not found"
    return m.group(1)


# ---- conf/oe5xrx-boot.inc: exec its def function with a fake datastore ----

class _Fatal(Exception):
    pass


class _FakeBB:
    @staticmethod
    def fatal(msg):
        raise _Fatal(msg)


class _FakeD:
    def __init__(self, **vals):
        self.vals = vals

    def getVar(self, name):
        return self.vals.get(name)


def _inc_config_func():
    """Extract + exec `def oe5xrx_boot_config(d)` from the inc (plain Python)."""
    inc = _read(*_INC)
    m = re.search(r"^def oe5xrx_boot_config\(d\):\n(?:(?:[ \t].*)?\n)+", inc,
                  re.M)
    assert m, "def oe5xrx_boot_config(d) missing in oe5xrx-boot.inc"
    ns = {"bb": _FakeBB}
    exec(m.group(0), ns)
    return ns["oe5xrx_boot_config"]


def _cfg(overlays="oe5xrx-ina226", test="", tag="dev"):
    return _inc_config_func()(_FakeD(OE5XRX_DT_OVERLAYS=overlays,
                                     OE5XRX_BOOT_TEST=test,
                                     OE5XRX_RELEASE_TAG=tag))


def test_inc_defaults():
    lines = [ln.strip() for ln in _code_lines(_read(*_INC))]
    assert 'OE5XRX_DT_OVERLAYS ??= "oe5xrx-ina226"' in lines
    assert 'OE5XRX_BOOT_TEST ??= ""' in lines
    # Same weak default as the image recipe (local builds = dev).
    assert 'OE5XRX_RELEASE_TAG ??= "dev"' in lines
    assert any(ln.startswith("python __anonymous") for ln in lines), \
        "the inc must apply oe5xrx_boot_config at parse time"


def test_both_recipes_require_the_inc():
    for parts in (_UBOOT_AB, _OVL_RECIPE):
        assert "require conf/oe5xrx-boot.inc" in _code_lines(_read(*parts)), \
            parts[-1]


@pytest.mark.parametrize("overlays,test,expected", [
    ("oe5xrx-ina226", "", ["oe5xrx-ina226"]),
    ("", "", []),
    ("oe5xrx-ina226", "marker", ["oe5xrx-ina226", "oe5xrx-test-marker"]),
    ("oe5xrx-ina226", "overlay-broken", ["oe5xrx-ina226", "oe5xrx-test-broken"]),
    ("oe5xrx-ina226", "stage2-broken", ["oe5xrx-ina226"]),
    ("  a-1   b2 ", "", ["a-1", "b2"]),
])
def test_effective_overlay_list(overlays, test, expected):
    cfg = _cfg(overlays, test)
    assert cfg["OE5XRX_DT_OVERLAYS_EFFECTIVE"] == " ".join(expected)
    assert cfg["OE5XRX_DT_OVERLAYS_CSV"] == ",".join(expected)
    assert cfg["OE5XRX_OVERLAYS_BOOTARG"] == (
        " oe5xrx.overlays=ok:" + ",".join(expected) if expected else "")


@pytest.mark.parametrize("bad", ["Oe5xrx", "a_b", "a.b", "a;b", "a$b", "a,b"])
def test_invalid_overlay_name_is_fatal(bad):
    with pytest.raises(_Fatal):
        _cfg(f"oe5xrx-ina226 {bad}")


def test_duplicate_overlay_is_fatal():
    with pytest.raises(_Fatal):
        _cfg("oe5xrx-ina226 oe5xrx-ina226")


def test_unknown_boot_test_value_is_fatal():
    with pytest.raises(_Fatal):
        _cfg(test="bogus")


@pytest.mark.parametrize("test", ["marker", "stage2-broken", "overlay-broken"])
def test_boot_test_switch_guarded_against_release(test):
    # Allowed in dev builds (an unset tag is a local build == "dev") ...
    _cfg(test=test, tag="dev")
    _cfg(test=test, tag=None)
    # ... but a release build carrying a fault switch must never parse.
    for tag in ("v1", "2026.11.04-16", "DEV", "dev2"):
        with pytest.raises(_Fatal):
            _cfg(test=test, tag=tag)
    # The release tag alone never trips the guard.
    assert _cfg(test="", tag="2026.11.04-16")["OE5XRX_DT_OVERLAYS_EFFECTIVE"] \
        == "oe5xrx-ina226"


def test_direct_test_overlay_guarded_against_release():
    # A test overlay put straight into OE5XRX_DT_OVERLAYS (bypassing the
    # OE5XRX_BOOT_TEST switch) is just as fatal in a release build ...
    for overlays in ("oe5xrx-ina226 oe5xrx-test-marker", "oe5xrx-test-broken"):
        _cfg(overlays, tag="dev")
        _cfg(overlays, tag=None)
        with pytest.raises(_Fatal):
            _cfg(overlays, tag="2026.11.04-16")
    # ... while a non-test overlay that merely contains "test" is fine.
    _cfg("oe5xrx-ina226 oe5xrx-testbench", tag="2026.11.04-16")


def test_inc_documents_no_machine_override():
    assert "never machine-override oe5xrx_dt_overlays" in \
        _read(*_INC).lower()


def test_kas_boot_test_overlays():
    seen = set()
    for rel, value in _TEST_YMLS.items():
        doc = yaml.safe_load(_read(rel))
        assert doc["header"]["version"] == 15, rel
        # Overlays only — never a machine/target/repo of their own.
        assert set(doc) == {"header", "local_conf_header"}, rel
        conf = "\n".join(doc["local_conf_header"].values())
        sets = re.findall(r'^\s*OE5XRX_BOOT_TEST\s*=\s*"([^"]*)"\s*$', conf,
                          re.M)
        assert sets == [value], f"{rel}: must set exactly OE5XRX_BOOT_TEST={value!r}"
        _cfg(test=value)  # a valid value for the inc
        seen.add(value)
    assert seen == {"marker", "stage2-broken", "overlay-broken"}


def test_release_kas_configs_do_not_set_boot_test():
    for rel in ("oe5xrx.yml", "raspberrypi4-64.yml", "qemux86-64.yml",
                "include/raspberrypi.yml"):
        assert "OE5XRX_BOOT_TEST" not in _read(rel), rel


# ---- u-boot-ab: stage 2 rendered by sed, installed into the rootfs ---------

_SED_RE = re.compile(r"-e\s+'s\|(@[A-Z0-9_]+@)\|\$\{([A-Z0-9_]+)\}\|g'")


def _recipe_sed_exprs():
    body = _shell_func(_read(*_UBOOT_AB), "do_compile")
    return _SED_RE.findall(body)


def test_recipe_sed_handles_every_template_placeholder():
    exprs = _recipe_sed_exprs()
    handled = [ph for ph, _ in exprs]
    assert sorted(handled) == sorted({PH_OVERLAYS, PH_OVERLAYS_CSV,
                                      PH_OVERLAYS_BOOTARG})
    in_template = set(re.findall(r"@OE5XRX_[A-Z0-9_]+@",
                                   read_stage2_template()))
    assert in_template == set(handled)
    # Each placeholder maps to the variable the inc derives for it.
    assert dict(exprs) == {
        PH_OVERLAYS: "OE5XRX_DT_OVERLAYS_EFFECTIVE",
        PH_OVERLAYS_CSV: "OE5XRX_DT_OVERLAYS_CSV",
        PH_OVERLAYS_BOOTARG: "OE5XRX_OVERLAYS_BOOTARG",
    }


@pytest.mark.parametrize("overlays,test", [
    ("oe5xrx-ina226", ""),
    ("", ""),
    ("oe5xrx-ina226", "marker"),
    ("oe5xrx-ina226", "overlay-broken"),
    ("oe5xrx-ina226 oe5xrx-foo2 x", ""),
])
def test_recipe_sed_render_is_byte_identical_to_render_stage2(
        tmp_path, overlays, test):
    if shutil.which("sed") is None:
        pytest.skip("sed not installed")
    cfg = _cfg(overlays, test)
    # BitBake expands ${VAR} before the shell runs; do the same here.
    args = []
    for ph, var in _recipe_sed_exprs():
        args += ["-e", f"s|{ph}|{cfg[var]}|g"]
    rendered = subprocess.run(
        ["sed", *args, _path(*_UBOOT_AB_FILES, "boot-stage2.cmd.in")],
        check=True, capture_output=True).stdout
    names = cfg["OE5XRX_DT_OVERLAYS_EFFECTIVE"].split()
    expected = render_stage2(read_stage2_template(), names).encode()
    assert rendered == expected
    assert b"@OE5XRX_" not in rendered


def test_recipe_fails_on_unrendered_placeholder():
    body = _shell_func(_read(*_UBOOT_AB), "do_compile")
    assert re.search(r"grep -q '@OE5XRX_'.*\n\s*bbfatal", body), \
        "do_compile must bbfatal if a placeholder survived rendering"


def test_stage2_recipe_installs_to_rootfs_boot():
    bb = _read(*_UBOOT_AB)
    code = _code_lines(bb)
    assert any("file://boot-stage2.cmd.in" in ln for ln in code)
    assert any("file://boot-stage2-test-broken.cmd" in ln for ln in code)
    comp = _shell_func(bb, "do_compile")
    assert "-d ${UNPACKDIR}/boot-stage2.cmd ${UNPACKDIR}/boot-stage2.scr" in comp
    inst = _shell_func(bb, "do_install")
    assert "install -d ${D}/boot\n" in inst
    assert ("install -m 0644 ${UNPACKDIR}/boot-stage2.scr "
            "${D}/boot/boot-stage2.scr") in inst
    files = [ln for ln in code if ln.startswith("FILES:${PN}")]
    assert len(files) == 1
    assert "/boot/boot-stage2.scr" in files[0].split()
    assert "/boot/boot-stage2.cmd" in files[0].split()
    # Stage 1 stays the FAT boot.scr, deployed as oe5xrx-boot.scr.
    assert "${DEPLOYDIR}/oe5xrx-boot.scr" in _shell_func(bb, "do_deploy")
    assert "boot-stage2" not in _shell_func(bb, "do_deploy")
    # Overlay list + fault switch are part of the task signature.
    vardeps = [ln for ln in code if ln.startswith("do_compile[vardeps]")]
    assert vardeps
    for var in ("OE5XRX_DT_OVERLAYS_EFFECTIVE", "OE5XRX_DT_OVERLAYS_CSV",
                "OE5XRX_OVERLAYS_BOOTARG", "OE5XRX_BOOT_TEST"):
        assert any(var in ln for ln in vardeps), var


def test_stage2_broken_switch_ships_echo_only_script():
    comp = _shell_func(_read(*_UBOOT_AB), "do_compile")
    assert '[ "${OE5XRX_BOOT_TEST}" = "stage2-broken" ]' in comp
    assert "${UNPACKDIR}/boot-stage2-test-broken.cmd" in comp
    script = _code_lines(_read(*_UBOOT_AB_FILES, "boot-stage2-test-broken.cmd"))
    # Only echoes and falls off the end: stage 1 boots its fallback with
    # oe5xrx.stage2=failed. No boot, no env writes, no exit/return.
    assert script and all(ln.strip().startswith("echo ") for ln in script)
    assert any("OE5XRX TEST FAULT" in ln for ln in script)


# ---- oe5xrx-dt-overlays: into the rootfs, not FAT ---------------------------

def test_overlay_recipe_installs_listed_overlays_into_rootfs():
    bb = _read(*_OVL_RECIPE)
    code = _code_lines(bb)
    for dts in ("oe5xrx-ina226-overlay.dts", "oe5xrx-test-marker-overlay.dts",
                "oe5xrx-test-broken-overlay.dts"):
        assert any(f"file://{dts}" in ln for ln in code), dts
        assert os.path.exists(_path(*_OVL_FILES, dts)), dts
    comp = _shell_func(bb, "do_compile")
    assert "${OE5XRX_DT_OVERLAYS_EFFECTIVE}" in comp
    assert "dtc -@ -I dts -O dtb" in comp
    inst = _shell_func(bb, "do_install")
    assert "install -d ${D}/boot/overlays" in inst
    assert "${D}/boot/overlays/$n.dtbo" in inst
    assert any(ln.startswith("FILES:${PN}") and "/boot/overlays" in ln
               for ln in code)
    # No more deploy/FAT route.
    assert "deploy" not in " ".join(ln for ln in code if ln.startswith("inherit"))
    assert "DEPLOYDIR" not in bb
    assert 'PACKAGE_ARCH = "${MACHINE_ARCH}"' in code
    assert any(ln.startswith("do_compile[vardeps]")
               and "OE5XRX_DT_OVERLAYS_EFFECTIVE" in ln for ln in code)
    # An empty overlay list must still produce an installable package.
    assert 'ALLOW_EMPTY:${PN} = "1"' in code


def _dtc(tmp_path, dts_name):
    if shutil.which("dtc") is None or shutil.which("fdtget") is None:
        if os.environ.get("CI"):
            pytest.fail("dtc/fdtget missing in CI (install device-tree-compiler)")
        pytest.skip("dtc/fdtget not installed")
    out = tmp_path / (dts_name.replace("-overlay.dts", ".dtbo"))
    subprocess.run(["dtc", "-@", "-q", "-I", "dts", "-O", "dtb",
                    "-o", str(out), _path(*_OVL_FILES, dts_name)], check=True)
    return out


def _fdtget(dtb, node, prop):
    return subprocess.run(["fdtget", str(dtb), node, prop], check=True,
                          capture_output=True, text=True).stdout.strip()


def test_test_overlays_compile(tmp_path):
    broken = _dtc(tmp_path, "oe5xrx-test-broken-overlay.dts")
    # Unresolvable on any base DTB: a label that does not exist.
    assert _fdtget(broken, "/__fixups__", "oe5xrx_no_such_label") \
        == "/fragment@0:target:0"
    marker = _dtc(tmp_path, "oe5xrx-test-marker-overlay.dts")
    assert _fdtget(marker, "/fragment@0", "target-path") == "/"
    assert _fdtget(marker, "/fragment@0/__overlay__", "oe5xrx,test-marker") \
        == "slot-overlay"


def test_every_overlay_name_has_a_dts():
    for name in ("oe5xrx-ina226", "oe5xrx-test-marker", "oe5xrx-test-broken"):
        assert os.path.exists(_path(*_OVL_FILES, f"{name}-overlay.dts")), name


# ---- image + config.txt -----------------------------------------------------

def test_overlay_installed_into_rootfs_not_fat():
    lines = _code_lines(_read(*_IMAGE))
    assert not any(".dtbo" in ln for ln in lines
                   if ln.startswith("IMAGE_BOOT_FILES")), \
        "own overlays must not go onto the FAT partition"
    assert not any("oe5xrx-dt-overlays" in ln for ln in lines
                   if ln.startswith("WKS_FILE_DEPENDS"))
    assert any(ln.startswith("IMAGE_INSTALL:append:raspberrypi4-64")
               and "oe5xrx-dt-overlays" in ln.split("=", 1)[1]
               for ln in lines)
    # Stage 1 keeps going onto FAT as boot.scr.
    assert any(ln.startswith("IMAGE_BOOT_FILES:append:raspberrypi4-64")
               and "oe5xrx-boot.scr;boot.scr" in ln for ln in lines)


def test_config_txt_has_no_own_overlays():
    lines = _code_lines(_read("raspberrypi4-64.yml"))
    assert any(ln.strip() == 'ENABLE_I2C = "1"' for ln in lines)
    extra = [ln for ln in lines if ln.strip().startswith("RPI_EXTRA_CONFIG")]
    assert len(extra) == 1
    assert "otg_mode=1" in extra[0], "USB XHCI (otg_mode=1) must stay"
    assert "dtoverlay=oe5xrx-" not in extra[0]


# ---- U-Boot: fdt overlay support + guard ------------------------------------

def test_uboot_fdt_overlay_fragment_and_guard():
    frag = _code_lines(_read(*_UBOOT_FILES, "oe5xrx-fdt-overlay.cfg"))
    assert "CONFIG_OF_LIBFDT_OVERLAY=y" in frag
    assert "CONFIG_CMD_FDT=y" in frag

    bb = _read(*_UBOOT_APPEND)
    code = _code_lines(bb)
    src = [ln for ln in code if ln.startswith("SRC_URI")]
    # Still ONE append line carrying every fragment.
    assert len(src) == 1
    assert src[0].startswith("SRC_URI:append:raspberrypi4-64")
    for f in ("oe5xrx-ext4.cfg", "oe5xrx-wdt.cfg", "oe5xrx-env.cfg",
              "oe5xrx-fdt-overlay.cfg"):
        assert f"file://{f}" in src[0], f

    guard = _shell_func(bb, "do_configure:append:raspberrypi4-64")
    for pat in ("^CONFIG_OF_LIBFDT_OVERLAY=y", "^CONFIG_CMD_FDT=y",
                # Existing env guards stay untouched.
                "^CONFIG_ENV_REDUNDANT=y",
                "^CONFIG_ENV_OFFSET=0x4005000$",
                "^CONFIG_ENV_OFFSET_REDUND=0x4105000$"):
        m = re.search(r"if ! grep -q '" + re.escape(pat)
                      + r"' \"\$\{B\}/\.config\"; then\n\s*bbfatal ", guard)
        assert m, f"missing bbfatal guard for {pat}"
