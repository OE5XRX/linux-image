import bz2
import hashlib

import pytest
import yaml

import image_ops
import seed

pytestmark = pytest.mark.unit


def test_sha256_file(tmp_path):
    p = tmp_path / "f"
    p.write_bytes(b"abc")
    assert image_ops.sha256_file(str(p)) == hashlib.sha256(b"abc").hexdigest()


def test_bz2_roundtrip(tmp_path):
    src = tmp_path / "s"
    src.write_bytes(b"x" * 1000)
    dst = tmp_path / "s.bz2"
    image_ops.bz2_compress(str(src), str(dst))
    assert bz2.decompress(dst.read_bytes()) == b"x" * 1000


def test_decompress_wic_passthrough_and_bz2(tmp_path):
    raw = tmp_path / "a.wic"
    raw.write_bytes(b"WIC")
    out1 = image_ops.decompress_wic(str(raw), str(tmp_path / "o1.wic"))
    assert open(out1, "rb").read() == b"WIC"

    comp = tmp_path / "b.wic.bz2"
    comp.write_bytes(bz2.compress(b"WIC2"))
    out2 = image_ops.decompress_wic(str(comp), str(tmp_path / "o2.wic"))
    assert open(out2, "rb").read() == b"WIC2"


def test_render_config_yaml_has_tuned_timers():
    txt = seed.render_config_yaml("http://10.0.2.2:8080")
    d = yaml.safe_load(txt)
    assert d["server_url"] == "http://10.0.2.2:8080"
    assert d["heartbeat_interval"] == 10 and d["ota_check_interval"] == 1
    assert d["station_id"] == 1 and d["bootloader"] == "grub"
    assert d["ed25519_key_path"] == "/etc/stationagent/device_key.pem"


def test_gen_ed25519_key_writes_pem(tmp_path):
    dst = tmp_path / "k.pem"
    seed.gen_ed25519_key(str(dst))
    assert dst.read_bytes().startswith(b"-----BEGIN PRIVATE KEY-----")
