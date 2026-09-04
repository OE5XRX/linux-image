"""A1 — audio image foundation okay-gate (Spec 0 §7 row A / §8).

Boots the built qemux86-64 image and, over the serial console, asserts the
Session-A audio substrate:

  * oe5xrx-pipewire + oe5xrx-wireplumber system services are active,
  * the GStreamer bridge elements (opusenc/opusdec/pipewiresrc/pipewiresink)
    are present,
  * WirePlumber named the sim slot node oe5xrx.slot1,
  * ~0.6 s recorded off oe5xrx.slot1 (the snd-aloop 1 kHz tone shim) shows a
    clean 1 kHz FFT peak — computed on the host by goertzel.py.

The self-check runs in the guest (tests/audio/audio_selfcheck.sh); it records
the tone and ships the WAV back as base64 over the console so the guest needs no
Python. This is the same known-tone assertion the CM4 bench will run against a
real SA818 / injected RF tone.
"""

from __future__ import annotations

import base64
import binascii
import os
import subprocess
import sys

import pytest

pytestmark = pytest.mark.qemu

_HERE = os.path.dirname(__file__)
_AUDIO_DIR = os.path.abspath(os.path.join(_HERE, "..", "audio"))
_SELFCHECK = os.path.join(_AUDIO_DIR, "audio_selfcheck.sh")
_GOERTZEL = os.path.join(_AUDIO_DIR, "goertzel.py")

_PROMPT = "OE5XRX-AUDIO-SH> "


def _login(con, markers):
    con.expect(markers["banner_re"], timeout=900)
    con.expect(markers["login_re"], timeout=300)
    con.sendline("root")
    # Empty root password on the qemu/dev image: a Password: prompt may or may
    # not appear depending on getty/pam config — handle both.
    idx = con.expect(["Password:", r"root@[^#]*# ", r"# "], timeout=60)
    if idx == 0:
        con.sendline("")
        con.expect(r"# ", timeout=60)
    # Pin a unique prompt so command boundaries are unambiguous over a noisy
    # console (kernel log lines, service output).
    con.sendline(f"export PS1='{_PROMPT}'")
    con.expect(_PROMPT, timeout=30)
    con.expect(_PROMPT, timeout=30)  # echo of the command itself


def _run(con, cmd, timeout=120):
    con.sendline(cmd)
    con.expect(_PROMPT, timeout=timeout)
    return con.before


def test_a1_audio_foundation(qemu_target, built_wic, expected_tag):
    import seed

    qemu_target.flash(built_wic)
    qemu_target.reset_ab_state()
    # The agent needs a config to boot cleanly to multi-user; reuse the OTA
    # seed with a dummy URL (no OTA server needed for this test).
    key_pem = qemu_target.work_dir + "/device_key.pem"
    seed.gen_ed25519_key(key_pem)
    qemu_target.seed_config(seed.render_config_yaml("http://10.0.2.2:1/"), key_pem)

    con = qemu_target.power_on()
    _login(con, qemu_target.boot_markers())

    # Push the self-check into the guest as base64 (one line, no quoting hazards).
    with open(_SELFCHECK, "rb") as f:
        sc_b64 = base64.b64encode(f.read()).decode()
    _run(con, f"printf '%s' '{sc_b64}' | base64 -d > /tmp/sc.sh", timeout=60)

    # Run it. It loops until the services/node are up, records the tone, and
    # streams the WAV between the B64 markers. Generous timeout for TCG.
    con.sendline("sh /tmp/sc.sh")

    # Either the WAV markers appear, or the script fails early (services/gst/node
    # missing) and prints result=FAIL. Match both so an early failure surfaces
    # its reason immediately instead of hanging until the 600 s timeout.
    idx = con.expect(["AUDIO-WAV-B64-BEGIN", "AUDIO-SELFTEST result=FAIL"], timeout=600)
    if idx == 1:
        con.expect(r"\r?\n", timeout=10)
        pytest.fail(f"in-guest self-check failed early (result=FAIL{con.before})")
    con.expect("AUDIO-WAV-B64-END", timeout=600)
    blob = con.before
    con.expect(["AUDIO-SELFTEST result=PASS", "AUDIO-SELFTEST result=FAIL"], timeout=60)
    assert "FAIL" not in con.after, f"in-guest self-check failed: {con.after}{con.before[:200]!r}"

    # Reassemble base64 from the B64:-tagged line(s) only; any stray console line
    # (no B64: prefix) is discarded wholesale rather than merged byte-wise.
    b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
    b64 = "".join(
        "".join(c for c in line.strip()[4:] if c in b64_chars)
        for line in blob.splitlines()
        if line.strip().startswith("B64:")
    )
    try:
        wav = base64.b64decode(b64, validate=True)
    except binascii.Error as e:
        pytest.fail(f"could not decode WAV base64 from console: {e}")
    assert len(wav) > 128, f"recovered WAV too small ({len(wav)} bytes)"

    wav_path = os.path.join(qemu_target.work_dir, "rx.wav")
    with open(wav_path, "wb") as f:
        f.write(wav)

    # Host-side FFT verdict: the recorded slot1 tap must be a clean 1 kHz sine.
    proc = subprocess.run(
        [sys.executable, _GOERTZEL, wav_path, "1000"],
        capture_output=True, text=True,
    )
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    assert proc.returncode == 0, "no dominant 1 kHz peak in the slot1 recording"
