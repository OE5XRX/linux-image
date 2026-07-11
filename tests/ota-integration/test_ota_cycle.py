"""T2 — the money test: a cross-build A/B OTA cycle.

Slot A = the LAST PUBLISHED RELEASE, slot B = the BUILD UNDER TEST. This MUST
be a cross-build pair: same-build A/B would coincidentally match ESP FAT UUIDs
and hide the #37 bug (ESP mounted by UUID → OTA'd slot mismatch → emergency
mode). It also catches #36 (unrelabelled slot B → unbootable → rollback).
"""

import os

import pytest

import image_ops
import seed
from helpers import wait_until

pytestmark = pytest.mark.qemu


def test_t2_cross_build_ota_boots_new_slot_and_commits(
    qemu_target, dummy_factory, built_wic, last_release_wic, expected_tag
):
    # Build the OTA payload the way station-manager does: extract root_a (ext4)
    # from the NEW build's wic, bz2-compress, checksum the compressed blob.
    new_wic = image_ops.decompress_wic(
        built_wic, os.path.join(qemu_target.work_dir, "new-build.wic")
    )
    payload = os.path.join(qemu_target.work_dir, "rootfs.bz2")
    checksum, size = image_ops.extract_rootfs_bz2(new_wic, payload)

    dummy = dummy_factory(payload_path=payload, checksum=checksum, size=size,
                          target_tag=expected_tag, offer_update=True)
    dummy.result_status = "pending"

    # Slot A = last release. Cross-build vs slot B (the new build under test).
    qemu_target.flash(last_release_wic)
    qemu_target.reset_ab_state()
    url = qemu_target.dut_server_url(dummy.port)
    key_pem = qemu_target.work_dir + "/device_key.pem"
    seed.gen_ed25519_key(key_pem)
    qemu_target.seed_config(seed.render_config_yaml(url), key_pem)

    con = qemu_target.power_on()
    markers = qemu_target.boot_markers()

    # Slot A boots (old tag), agent checks in, then downloads + installs.
    con.expect(markers["banner_re"], timeout=900)
    con.expect(markers["login_re"], timeout=180)

    assert wait_until(lambda: dummy.downloads >= 1, timeout=300), "agent never downloaded"
    assert wait_until(
        lambda: any(u.get("status") == "rebooting" for u in dummy.status_updates),
        timeout=300,
    ), "agent never reported 'rebooting'"

    # After the guest reboots, the post-reboot /check/ must report the trial so
    # the agent runs verify+commit.
    dummy.result_status = "rebooting"

    # Slot B boots with the NEW tag (this is where #37/#36 would fail: emergency
    # mode, or rollback to the old tag).
    con.expect(markers["banner_re"], timeout=900)
    slot_b_ver = con.match.group(1)
    con.expect(markers["login_re"], timeout=180)
    assert expected_tag in slot_b_ver or slot_b_ver in expected_tag, (
        f"post-OTA banner {slot_b_ver!r} != expected {expected_tag!r} (rolled back?)"
    )

    # Application layer: the agent commits at the new version.
    assert wait_until(
        lambda: dummy.last_reported_version() == expected_tag, timeout=300
    ), f"agent never committed at {expected_tag} (commits={dummy.commits})"
