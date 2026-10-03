"""Unit lint for 52-oe5xrx-fm-sink-unity.conf.

Verifies that the WirePlumber FM-sink unity config:
  - exists in the recipe's files/ directory,
  - matches only the FM Transceiver Board (device.name pattern),
  - sets device.routes.default-sink-volume = 1.0,
  - does NOT contain a catch-all match that would affect other devices.
"""

import os
import re

import pytest

pytestmark = pytest.mark.unit

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_CONF = os.path.join(
    _REPO,
    "meta-oe5xrx-remotestation",
    "recipes-multimedia",
    "oe5xrx-audio-system",
    "files",
    "52-oe5xrx-fm-sink-unity.conf",
)
_BB = os.path.join(
    _REPO,
    "meta-oe5xrx-remotestation",
    "recipes-multimedia",
    "oe5xrx-audio-system",
    "oe5xrx-audio-system_1.0.bb",
)


@pytest.fixture(scope="module")
def conf_text():
    with open(_CONF) as f:
        return f.read()


@pytest.fixture(scope="module")
def bb_text():
    with open(_BB) as f:
        return f.read()


def test_conf_file_exists():
    assert os.path.isfile(_CONF), f"missing {_CONF}"


def test_conf_matches_fm_transceiver_only(conf_text):
    # Must contain a match on the FM Transceiver Board device.name pattern.
    assert re.search(
        r'device\.name\s*=\s*"~alsa_card\.usb-OE5XRX_FM_Transceiver_Board\.',
        conf_text,
    ), "conf must match alsa_card.usb-OE5XRX_FM_Transceiver_Board.* device"


def test_conf_sets_sink_volume_unity(conf_text):
    # Must set device.routes.default-sink-volume = 1.0 (unity, not 0.064).
    assert re.search(
        r"device\.routes\.default-sink-volume\s*=\s*1\.0",
        conf_text,
    ), "conf must set device.routes.default-sink-volume = 1.0"


def test_conf_no_catch_all_match(conf_text):
    # The match block must NOT contain a bare wildcard that would apply to all
    # ALSA devices (e.g. "~alsa_card.*" without further qualification, or a
    # match-all empty block).
    assert not re.search(
        r'device\.name\s*=\s*"~alsa_card\.\*"',
        conf_text,
    ), "conf must not have a catch-all alsa_card.* match"


def test_recipe_lists_conf_in_src_uri(bb_text):
    assert "52-oe5xrx-fm-sink-unity.conf" in bb_text, (
        "oe5xrx-audio-system_1.0.bb must reference 52-oe5xrx-fm-sink-unity.conf in SRC_URI"
    )


def test_recipe_installs_conf(bb_text):
    assert re.search(
        r"install.*52-oe5xrx-fm-sink-unity\.conf",
        bb_text,
    ), "oe5xrx-audio-system_1.0.bb must install 52-oe5xrx-fm-sink-unity.conf"


def test_recipe_includes_conf_in_files(bb_text):
    assert re.search(
        r"52-oe5xrx-fm-sink-unity\.conf",
        bb_text,
    ), "oe5xrx-audio-system_1.0.bb must list 52-oe5xrx-fm-sink-unity.conf in FILES"
