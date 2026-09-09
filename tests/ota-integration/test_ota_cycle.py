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

    # Partition-layout guard. A cross-build OTA only works when both sides share
    # the A/B slot geometry; when a build changes the slot size, the new rootfs
    # cannot be written into the last release's smaller slot (install_to_slot
    # ENOSPC) and a one-time fleet reflash is required. Such a change must NOT
    # pass silently — a developer has to actively acknowledge it via
    # OTA_IT_ACK_LAYOUT_CHANGE=1 (release.yml: acknowledge_layout_change=true).
    # Default: fail loud and fast (don't waste 5 min on a doomed OTA timeout).
    with image_ops.loop_attach(new_wic) as _d:
        _new_slot = image_ops.part_size_bytes(f"{_d}p{image_ops.ROOT_A_PARTNUM}")
    with image_ops.loop_attach(qemu_target.disk) as _d:
        _rel_slot = image_ops.part_size_bytes(f"{_d}p{image_ops.ROOT_A_PARTNUM}")
    if _new_slot != _rel_slot:
        _msg = (
            f"PARTITION-LAYOUT CHANGE: last-release root_a={_rel_slot}B vs "
            f"build root_a={_new_slot}B. A cross-build OTA is impossible across "
            f"this boundary and a one-time fleet reflash is required."
        )
        if os.environ.get("OTA_IT_ACK_LAYOUT_CHANGE") == "1":
            pytest.skip(f"{_msg} Acknowledged (OTA_IT_ACK_LAYOUT_CHANGE=1) — "
                        f"cross-build OTA intentionally not tested across the change.")
        pytest.fail(f"{_msg} If intentional, re-run the release with "
                    f"acknowledge_layout_change=true (sets OTA_IT_ACK_LAYOUT_CHANGE=1).")

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
    # Exact match: banner_re captures the tag token, so a substring check could
    # false-green a truncated/suffixed tag and weaken the release gate.
    assert slot_b_ver == expected_tag, (
        f"post-OTA banner {slot_b_ver!r} != expected {expected_tag!r} (rolled back?)"
    )

    # Application layer: the agent commits at the new version.
    assert wait_until(
        lambda: dummy.last_reported_version() == expected_tag, timeout=300
    ), f"agent never committed at {expected_tag} (commits={dummy.commits})"

    # Durability: the commit must have cleared the trial flags (bootcount=0,
    # upgrade_available=0). If it didn't, the bootloader would roll back to slot
    # A on the next power-cycle. Prove it stuck by rebooting (on-disk grubenv
    # preserved) and asserting we come up on slot B / the new tag again.
    qemu_target.reset()
    con = qemu_target.console()
    con.expect(markers["banner_re"], timeout=900)
    reboot_ver = con.match.group(1)
    con.expect(markers["login_re"], timeout=180)
    assert reboot_ver == expected_tag, (
        f"post-commit reboot came up {reboot_ver!r}, expected {expected_tag!r} — "
        f"trial flags were not cleared (rolled back to slot A)"
    )
