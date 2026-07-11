import json
import urllib.error
import urllib.request

import pytest

from dummy_server import DummyOtaServer

pytestmark = pytest.mark.unit


def _post(url, obj):
    data = json.dumps(obj).encode()
    req = urllib.request.Request(
        url, data=data, method="POST",
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req) as r:
        return r.status, r.read()


def test_heartbeat_records_and_returns_ok():
    s = DummyOtaServer(payload_path=None, checksum=None, size=None, target_tag="T")
    s.start()
    try:
        st, body = _post(s.url + "/api/v1/heartbeat/",
                         {"os_version": "OE5XRX Remote Station T"})
        assert st == 200 and json.loads(body) == {"status": "ok"}
        assert s.heartbeats[-1]["os_version"] == "OE5XRX Remote Station T"
    finally:
        s.stop()


def test_check_204_when_no_update():
    s = DummyOtaServer(payload_path=None, checksum=None, size=None, target_tag="T")
    s.start()
    try:
        req = urllib.request.Request(
            s.url + "/api/v1/deployments/check/",
            data=b'{"current_version":"X"}', method="POST",
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req) as r:
            assert r.status == 204
            assert r.read() == b""
    finally:
        s.stop()


def test_check_200_offers_update_with_expected_fields(tmp_path):
    payload = tmp_path / "rootfs.bz2"
    payload.write_bytes(b"hello-bz2")
    s = DummyOtaServer(payload_path=str(payload), checksum="deadbeef",
                       size=9, target_tag="2026.07.11-15")
    s.offer_update = True
    s.start()
    try:
        st, body = _post(s.url + "/api/v1/deployments/check/",
                         {"current_version": "old"})
        d = json.loads(body)
        assert st == 200
        assert d["target_tag"] == "2026.07.11-15"
        assert d["checksum_sha256"] == "deadbeef"
        assert d["size_bytes"] == 9
        assert d["download_url"].endswith("/download/")
        assert "deployment_result_id" in d and "deployment_id" in d
    finally:
        s.stop()


def test_download_serves_payload_bytes(tmp_path):
    payload = tmp_path / "rootfs.bz2"
    payload.write_bytes(b"PAYLOAD")
    s = DummyOtaServer(payload_path=str(payload), checksum="x", size=7, target_tag="T")
    s.offer_update = True
    s.start()
    try:
        st, body = _post(s.url + "/api/v1/deployments/check/", {"current_version": "old"})
        url = json.loads(body)["download_url"]
        with urllib.request.urlopen(s.url + url) as r:
            assert r.status == 200 and r.read() == b"PAYLOAD"
        assert s.downloads == 1
    finally:
        s.stop()


def test_status_and_commit_recorded():
    s = DummyOtaServer(payload_path=None, checksum=None, size=None,
                       target_tag="2026.07.11-15")
    s.start()
    try:
        _post(s.url + "/api/v1/deployments/1/status/",
              {"status": "downloading", "error_message": ""})
        st, _ = _post(s.url + "/api/v1/deployments/commit/",
                      {"version": "2026.07.11-15"})
        assert st == 200
        assert s.status_updates[-1]["status"] == "downloading"
        assert s.status_updates[-1]["result_pk"] == "1"
        assert s.last_reported_version() == "2026.07.11-15"
    finally:
        s.stop()
