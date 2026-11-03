"""Static guards for the PowerBoard INA226 enablement on the CM4 (rpi) image
(contract `station-telemetry-interface` point 5): I2C on, INA2xx driver,
a DT overlay with ti,ina226 @0x40 (+5V) / @0x41 (+12V) on i2c1, deployed to
the firmware FAT partition and enabled from config.txt. Pure file-content
checks (plus a dtc compile when dtc is installed) — run on every PR via
`-m unit`; no build/qemu needed."""

import os
import shutil
import subprocess

import pytest

pytestmark = pytest.mark.unit

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_LAYER = "meta-oe5xrx-remotestation"
_OVERLAY_DIR = (_LAYER, "recipes-bsp", "oe5xrx-dt-overlays")
_DTS = _OVERLAY_DIR + ("files", "oe5xrx-ina226-overlay.dts")
_RECIPE = _OVERLAY_DIR + ("oe5xrx-dt-overlays_1.0.bb",)
_IMAGE = (_LAYER, "recipes-core", "images", "oe5xrx-remotestation-image.bb")
_KCFG = (_LAYER, "recipes-kernel", "linux", "files", "oe5xrx-ina226.cfg")


def _path(*parts):
    return os.path.join(_REPO, *parts)


def _read(*parts):
    with open(_path(*parts)) as f:
        return f.read()


def _code_lines(txt):
    """Non-comment, non-blank lines (BitBake/kas comments start with #)."""
    return [ln for ln in txt.splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")]


# ---- kernel driver ------------------------------------------------------

def test_kernel_fragment_enables_ina2xx():
    lines = _code_lines(_read(*_KCFG))
    assert any(ln.strip() in ("CONFIG_SENSORS_INA2XX=m",
                              "CONFIG_SENSORS_INA2XX=y") for ln in lines)


def test_kernel_fragment_wired_into_rpi_kernel_only():
    rpi = _read(_LAYER, "recipes-kernel", "linux",
                "linux-raspberrypi_%.bbappend")
    assert any("file://oe5xrx-ina226.cfg" in ln for ln in _code_lines(rpi))
    # qemux86-64 stays unchanged: the x86 kernel must not pull the fragment.
    yocto = _read(_LAYER, "recipes-kernel", "linux", "linux-yocto_%.bbappend")
    assert "oe5xrx-ina226.cfg" not in yocto


# ---- overlay source -----------------------------------------------------

def test_overlay_targets_i2c1_with_both_ina226():
    dts = "\n".join(ln.split("//", 1)[0] for ln in _read(*_DTS).splitlines())
    assert "/plugin/;" in dts
    assert "target = <&i2c1>;" in dts
    assert dts.count('compatible = "ti,ina226";') == 2
    assert "reg = <0x40>;" in dts
    assert "reg = <0x41>;" in dts
    # 10 mOhm shunt, in micro-ohms, on both sensors.
    assert dts.count("shunt-resistor = <10000>;") == 2
    # No ALERT pin is wired on the PowerBoard → no interrupts in the overlay.
    assert "interrupt" not in dts


def test_overlay_compiles_and_has_expected_nodes(tmp_path):
    if shutil.which("dtc") is None or shutil.which("fdtget") is None:
        # CI installs device-tree-compiler (ci.yml); never skip silently there.
        if os.environ.get("CI"):
            pytest.fail("dtc/fdtget missing in CI (install device-tree-compiler)")
        pytest.skip("dtc/fdtget not installed")
    out = tmp_path / "oe5xrx-ina226.dtbo"
    subprocess.run(["dtc", "-@", "-q", "-I", "dts", "-O", "dtb",
                    "-o", str(out), _path(*_DTS)], check=True)

    def get(node, prop, typ=None):
        cmd = ["fdtget"] + (["-t", typ] if typ else []) + [str(out), node, prop]
        return subprocess.run(cmd, check=True, capture_output=True,
                              text=True).stdout.strip()

    base = "/fragment@0/__overlay__"
    for addr, reg in (("40", "64"), ("41", "65")):
        node = f"{base}/ina226@{addr}"
        assert get(node, "compatible") == "ti,ina226"
        assert get(node, "reg", "u") == reg
        assert get(node, "shunt-resistor", "u") == "10000"
    # target = <&i2c1> must become a firmware-resolved fixup, not a raw phandle.
    assert get("/__fixups__", "i2c1") == "/fragment@0:target:0"


# ---- deploy to the firmware FAT partition + enable in config.txt --------

def test_overlay_recipe_deploys_dtbo():
    bb = _read(*_RECIPE)
    assert "file://oe5xrx-ina226-overlay.dts" in bb
    assert "dtc-native" in bb
    assert any(ln.startswith("inherit") and "deploy" in ln.split()
               for ln in _code_lines(bb)), "recipe must inherit deploy"
    assert "${DEPLOYDIR}/oe5xrx-ina226.dtbo" in bb
    # Only meaningful on the RPi (firmware applies overlays from config.txt).
    assert 'COMPATIBLE_MACHINE = "^(raspberrypi.*|.*cm4.*)$"' in bb


def test_image_routes_dtbo_onto_firmware_partition_rpi_only():
    lines = _code_lines(_read(*_IMAGE))
    boot = [ln for ln in lines if "oe5xrx-ina226.dtbo" in ln]
    assert boot, "oe5xrx-ina226.dtbo not in IMAGE_BOOT_FILES"
    assert all(ln.startswith("IMAGE_BOOT_FILES:append:raspberrypi4-64")
               for ln in boot)
    assert any("oe5xrx-ina226.dtbo;overlays/oe5xrx-ina226.dtbo" in ln
               for ln in boot)
    assert any(ln.startswith("WKS_FILE_DEPENDS:append:raspberrypi4-64")
               and "oe5xrx-dt-overlays" in ln for ln in lines)


def test_config_txt_enables_i2c_and_overlay():
    kas = _read("raspberrypi4-64.yml")
    lines = _code_lines(kas)
    # ENABLE_I2C=1 makes meta-raspberrypi's rpi-config emit dtparam=i2c_arm=on.
    assert any(ln.strip() == 'ENABLE_I2C = "1"' for ln in lines)
    extra = [ln for ln in lines if ln.strip().startswith("RPI_EXTRA_CONFIG")]
    assert len(extra) == 1
    assert "otg_mode=1" in extra[0], "USB XHCI (otg_mode=1) must stay"
    assert "dtoverlay=oe5xrx-ina226" in extra[0]


def test_qemu_config_untouched():
    for parts in (("qemux86-64.yml",), ("oe5xrx.yml",)):
        assert "ina226" not in _read(*parts)
