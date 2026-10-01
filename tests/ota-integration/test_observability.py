"""T-obs — debug-observability on-target smoke: the built qemu image boots to
login AND exposes the OS enablement (pstore mounted, persistent journal). Guards
the ramoops cmdline / kernel config / journald changes against boot regressions.
"""

import pytest

import seed

pytestmark = pytest.mark.qemu


def test_observability_sources_present(qemu_target, dummy_factory, built_wic,
                                       expected_tag):
    dummy = dummy_factory(target_tag=expected_tag, offer_update=False)

    qemu_target.flash(built_wic)
    qemu_target.reset_ab_state()

    url = qemu_target.dut_server_url(dummy.port)
    key_pem = qemu_target.work_dir + "/device_key.pem"
    seed.gen_ed25519_key(key_pem)
    qemu_target.seed_config(seed.render_config_yaml(url), key_pem)

    con = qemu_target.power_on()
    markers = qemu_target.boot_markers()

    # Boot must still reach login — the ramoops cmdline must not break boot.
    con.expect(markers["banner_re"], timeout=900)
    con.expect(markers["login_re"], timeout=180)

    # Log in on the serial console (dev image allows empty-password root).
    con.sendline("root")
    con.expect(r"[#$] ", timeout=60)

    # pstore filesystem is mounted (systemd mount-setup) once CONFIG_PSTORE=y —
    # proves the kernel fragment + reserve_mem wiring took effect on x86.
    con.sendline("mountpoint -q /sys/fs/pstore && echo PSTORE_OK || echo PSTORE_NO")
    con.expect(r"PSTORE_(OK|NO)", timeout=30)
    assert con.match.group(0) == "PSTORE_OK", "/sys/fs/pstore is not mounted"

    # Persistent journal active → --list-boots works and reports the storage.
    con.sendline("journalctl --list-boots >/dev/null 2>&1 && echo BOOTS_OK || echo BOOTS_NO")
    con.expect(r"BOOTS_(OK|NO)", timeout=30)
    assert con.match.group(0) == "BOOTS_OK", "journalctl --list-boots failed"
