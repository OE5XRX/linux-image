"""T1 — boot smoke: the freshly built image boots to multi-user (not emergency
mode) and the agent reaches the network. Dummy offers NO update."""

import pytest

import seed
from helpers import wait_until

pytestmark = pytest.mark.qemu


def test_t1_boots_and_agent_checks_in(qemu_target, dummy_factory, built_wic, expected_tag):
    dummy = dummy_factory(target_tag=expected_tag, offer_update=False)

    qemu_target.flash(built_wic)
    qemu_target.reset_ab_state()

    url = qemu_target.dut_server_url(dummy.port)
    key_pem = qemu_target.work_dir + "/device_key.pem"
    seed.gen_ed25519_key(key_pem)
    qemu_target.seed_config(seed.render_config_yaml(url), key_pem)

    con = qemu_target.power_on()
    markers = qemu_target.boot_markers()

    # Serial layer: banner (carries version) then login. Emergency mode reaches
    # neither, so this distinguishes the #37 failure.
    con.expect(markers["banner_re"], timeout=900)
    banner_ver = con.match.group(1)
    con.expect(markers["login_re"], timeout=180)

    # Application layer: the agent must check in reporting the expected version.
    got = wait_until(
        lambda: any(expected_tag in (h.get("os_version") or "") for h in dummy.heartbeats),
        timeout=300,
    )
    assert got, "agent never checked in with the expected version"
    assert expected_tag in banner_ver or banner_ver in expected_tag, (
        f"serial banner version {banner_ver!r} != expected {expected_tag!r}"
    )
