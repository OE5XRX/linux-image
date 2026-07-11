"""Data-partition config seeding for the OTA integration test.

We boot the identical production wic and only write the agent's config +
device key onto the data partition (partlabel `data`, partition 4), exactly
like real provisioning. data-init.sh preserves a pre-existing
etc-overlay/stationagent/config.yml (its copy is `[ ! -f ]`-guarded), so the
seed survives first boot.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
from contextlib import contextmanager

import yaml

from image_ops import DATA_PARTNUM, loop_attach

# Path on the data partition that etc-stationagent.mount overlays onto
# /etc/stationagent inside the guest.
_OVERLAY_SUBDIR = "etc-overlay/stationagent"


def render_config_yaml(server_url: str, station_id: int = 1,
                       key_path: str = "/etc/stationagent/device_key.pem") -> str:
    """Agent config pointing at the dummy server, with tuned-down timers so the
    OTA check + post-reboot commit happen in seconds rather than minutes."""
    cfg = {
        "server_url": server_url,
        "station_id": station_id,
        "ed25519_key_path": key_path,
        "heartbeat_interval": 10,   # minimum accepted by the agent
        "ota_check_interval": 1,    # check every heartbeat
        "log_level": "INFO",
        "bootloader": "grub",
        "terminal_enabled": False,
    }
    return yaml.safe_dump(cfg, default_flow_style=False, sort_keys=True)


def gen_ed25519_key(dest_pem_path: str) -> None:
    """Write an Ed25519 private key in PKCS#8 PEM. The dummy server does not
    verify signatures, but the agent's config requires a valid key file."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    key = Ed25519PrivateKey.generate()
    pem = key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    with open(dest_pem_path, "wb") as fh:
        fh.write(pem)


@contextmanager
def _mount_partition(wic_path: str, partnum: int):
    """Loop-attach wic_path and mount partition `partnum`; yield the mountpoint.
    Always unmounts + detaches. Requires root."""
    with loop_attach(wic_path) as dev:
        part = f"{dev}p{partnum}"
        mnt = tempfile.mkdtemp(prefix="ota-it-mnt-")
        subprocess.run(["mount", part, mnt], check=True)
        try:
            yield mnt
        finally:
            subprocess.run(["umount", mnt], check=False)
            os.rmdir(mnt)


def seed_data_partition(wic_path: str, config_yaml_text: str, key_pem_path: str) -> None:
    """Write config.yml + device_key.pem into etc-overlay/stationagent on the
    data partition of wic_path. Requires root."""
    with _mount_partition(wic_path, DATA_PARTNUM) as mnt:
        overlay = os.path.join(mnt, _OVERLAY_SUBDIR)
        os.makedirs(overlay, exist_ok=True)
        cfg_path = os.path.join(overlay, "config.yml")
        with open(cfg_path, "w") as fh:
            fh.write(config_yaml_text)
        os.chmod(cfg_path, 0o600)
        with open(key_pem_path, "rb") as src, \
                open(os.path.join(overlay, "device_key.pem"), "wb") as dst:
            dst.write(src.read())
        os.chmod(os.path.join(overlay, "device_key.pem"), 0o600)
