import pytest

from target import Cm4Target, QemuTarget

pytestmark = pytest.mark.unit


def test_qemu_boot_markers():
    t = QemuTarget()
    m = t.boot_markers()
    assert "OE5XRX Remote Station" in m["banner_re"]
    assert m["login_re"] == "login:"


def test_banner_re_captures_only_the_tag_not_trailing_ansi():
    import re
    t = QemuTarget()
    banner = t.boot_markers()["banner_re"]
    # getty emits ANSI escapes on the console; the capture must stop at the tag.
    for line, tag in [
        ("OE5XRX Remote Station dev\x1b[0m", "dev"),
        ("OE5XRX Remote Station 2026.07.11-15\x1b[K", "2026.07.11-15"),
        ("OE5XRX Remote Station 2026.07.11-15a\r\n", "2026.07.11-15a"),
    ]:
        assert re.search(banner, line).group(1) == tag


def test_banner_re_does_not_match_a_half_streamed_tag():
    # Regression: over a real serial console the banner arrives byte-by-byte.
    # Without a trailing terminator the regex must NOT match yet, so pexpect keeps
    # reading instead of capturing a truncated tag (the bug that read "2026.07.21-22"
    # as "20" / "2026.07.2" and failed the exact version assertion in the OTA gate).
    import re
    banner = QemuTarget().boot_markers()["banner_re"]
    for partial in [
        "OE5XRX Remote Station 20",
        "OE5XRX Remote Station 2026.07.2",
        "OE5XRX Remote Station 2026.07.21-22",  # full tag but terminator not yet streamed
    ]:
        assert re.search(banner, partial) is None, partial
    # Once the terminator arrives, the FULL tag is captured (not a prefix).
    assert re.search(banner, "OE5XRX Remote Station 2026.07.21-22\r\n").group(1) == "2026.07.21-22"


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
