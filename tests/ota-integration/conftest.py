"""Fixtures for the OTA integration tests.

Unit tests (`-m unit`) need none of this. The qemu tests (`-m qemu`) require
root (loop mount) + qemu-system-x86_64 + OVMF and the image artifact(s) passed
via environment:

  OTA_IT_WIC            path to the build-under-test wic (or .wic.bz2)   [T1, T2 slot B]
  OTA_IT_LAST_RELEASE_WIC  path to the previous release wic (slot A)     [T2, T3]
  OTA_IT_EXPECTED_TAG   version string baked into the build-under-test   [T1, T2]
"""

from __future__ import annotations

import os

import pytest

from dummy_server import DummyOtaServer
from target import QemuTarget


@pytest.fixture
def built_wic():
    path = os.environ.get("OTA_IT_WIC")
    if not path:
        pytest.skip("OTA_IT_WIC not set (build-under-test wic)")
    if not os.path.exists(path):
        pytest.skip(f"OTA_IT_WIC does not exist: {path}")
    return path


@pytest.fixture
def last_release_wic():
    path = os.environ.get("OTA_IT_LAST_RELEASE_WIC")
    if not path:
        pytest.skip("OTA_IT_LAST_RELEASE_WIC not set (cross-build slot A) — T2/T3 skipped")
    if not os.path.exists(path):
        pytest.skip(f"OTA_IT_LAST_RELEASE_WIC does not exist: {path}")
    return path


@pytest.fixture
def expected_tag():
    return os.environ.get("OTA_IT_EXPECTED_TAG", "dev")


@pytest.fixture
def qemu_target(tmp_path):
    t = QemuTarget(work_dir=str(tmp_path / "qemu"))
    os.makedirs(t.work_dir, exist_ok=True)
    try:
        yield t
    finally:
        t.power_off()


@pytest.fixture
def dummy_factory():
    """Create + start DummyOtaServers; all are stopped on teardown."""
    servers: list[DummyOtaServer] = []

    def make(payload_path=None, checksum=None, size=None, target_tag="dev",
             offer_update=False):
        s = DummyOtaServer(payload_path=payload_path, checksum=checksum,
                           size=size, target_tag=target_tag)
        s.offer_update = offer_update
        s.start()
        servers.append(s)
        return s

    try:
        yield make
    finally:
        for s in servers:
            s.stop()
