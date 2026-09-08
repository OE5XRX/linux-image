"""Partition-layout assertion on the build-under-test wic.

Guards the A/B rootfs slot size (see docs/superpowers/specs/
2026-09-08-robust-ab-env-larger-slots-design.md): root_a and root_b must be
2.5 GiB so an audio-heavy rootfs fits and OTA has headroom. A silent revert to
the old 1 GiB slot would break OTA installs (ENOSPC on the inactive slot).

x64 wic layout: 1=efi, 2=root_a, 3=root_b, 4=data.
"""

import os

import pytest

import image_ops

pytestmark = pytest.mark.qemu  # needs root+losetup, same env as the boot tests

EXPECTED_SLOT_BYTES = 2560 * 1024 * 1024  # 2.5 GiB, matches the .wks --fixed-size


def test_root_slots_are_2560_mib(built_wic, tmp_path):
    raw = image_ops.decompress_wic(built_wic, os.path.join(str(tmp_path), "layout.wic"))
    with image_ops.loop_attach(raw) as dev:
        for partnum in (2, 3):  # root_a, root_b
            size = image_ops.part_size_bytes(f"{dev}p{partnum}")
            assert size == EXPECTED_SLOT_BYTES, (
                f"slot p{partnum} is {size} bytes, expected {EXPECTED_SLOT_BYTES} "
                f"(2.5 GiB) — did the .wks --fixed-size regress?"
            )
