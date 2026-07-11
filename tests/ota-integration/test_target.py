import pytest

from target import Cm4Target, QemuTarget

pytestmark = pytest.mark.unit


def test_qemu_boot_markers():
    t = QemuTarget()
    m = t.boot_markers()
    assert "OE5XRX Remote Station" in m["banner_re"]
    assert m["login_re"] == "login:"


def test_qemu_dut_server_url_uses_slirp_alias():
    t = QemuTarget()
    assert t.dut_server_url(8080) == "http://10.0.2.2:8080"


def test_qemu_allocates_a_port_and_workdir():
    t = QemuTarget()
    assert isinstance(t.ssh_port, int) and t.ssh_port > 0
    assert t.disk.endswith("disk.wic")


def test_cm4_is_a_stub():
    c = Cm4Target()
    with pytest.raises(NotImplementedError):
        c.flash("x")
    with pytest.raises(NotImplementedError):
        c.power_on()
    with pytest.raises(NotImplementedError):
        c.dut_server_url(8080)
    # boot_markers is defined (interface fixed) and includes a u-boot marker
    assert "uboot_re" in c.boot_markers()
