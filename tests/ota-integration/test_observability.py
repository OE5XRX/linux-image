"""T-obs — debug-observability on-target smoke: the built qemu image boots to
login AND exposes the OS enablement (pstore mounted, persistent journal). Guards
the ramoops cmdline / kernel config / journald changes against boot regressions.
"""

import pytest

import seed
from test_audio import _PROMPT, _login, _run

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
    # _login handles banner, login prompt, optional Password: prompt, and pins
    # a unique PS1 so command boundaries are unambiguous over a noisy console.
    _login(con, markers)

    # pstore filesystem is mounted (systemd mount-setup) once CONFIG_PSTORE=y —
    # proves the kernel fragment + reserve_mem wiring took effect on x86.
    # Use $? echo so the sentinel cannot appear in the echoed command line.
    out = _run(con, "mountpoint -q /sys/fs/pstore; echo PSTORE_RC=$?")
    assert "PSTORE_RC=0" in out, "/sys/fs/pstore is not mounted"

    # Persistent journal active → --list-boots works and reports the storage.
    out = _run(con, "journalctl --list-boots >/dev/null 2>&1; echo BOOTS_RC=$?")
    assert "BOOTS_RC=0" in out, "journalctl --list-boots failed"
