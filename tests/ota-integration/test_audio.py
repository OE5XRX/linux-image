"""A1 — audio image foundation okay-gate (Spec 0 §7 row A / §8).

Boots the built qemux86-64 image and, over the serial console, asserts the
Session-A audio substrate:

  * oe5xrx-pipewire + oe5xrx-wireplumber system services are active,
  * the GStreamer bridge elements (opusenc/opusdec/pipewiresrc/pipewiresink)
    are present,
  * WirePlumber named the sim RX node oe5xrx.slot1,
  * RX gate: audio recorded off oe5xrx.slot1 (the snd-aloop 1 kHz tone shim)
    shows a clean 1 kHz FFT peak,
  * TX gate: a distinct 1500 Hz tone played into oe5xrx.slot1.tx and captured
    off the reverse-cable tap shows a clean 1500 Hz FFT peak.

Both FFT verdicts are computed on the host by goertzel.py. The self-check runs
in the guest (tests/audio/audio_selfcheck.sh); it records the tones and ships
the WAVs back as base64 over the console so the guest needs no Python. Same
known-tone assertion the CM4 bench will run against a real SA818 / RF tone.
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
    banner_tag = con.match.group(1)  # image version stamped in the boot banner
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
    # Sync on a command's OUTPUT (a unique sentinel), not on the echoed command:
    # terminal echo may be off, in which case waiting for the prompt string inside
    # the echoed PS1 assignment would hang. "SYNC-0-READY" appears only in stdout
    # ($? = 0 from the export); the echoed line keeps a literal "$?" and won't match.
    con.sendline("echo SYNC-$?-READY")
    con.expect("SYNC-0-READY", timeout=30)
    con.expect(_PROMPT, timeout=30)
    return banner_tag


def _run(con, cmd, timeout=120):
    con.sendline(cmd)
    con.expect(_PROMPT, timeout=timeout)
    return con.before


_B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="


def _reassemble_b64(blob):
    # Keep only B64:-tagged line(s); any stray console line is dropped wholesale.
    return "".join(
        "".join(c for c in line.strip()[4:] if c in _B64_CHARS)
        for line in blob.splitlines()
        if line.strip().startswith("B64:")
    )


def _capture_wav(con, begin, end):
    # Match the payload's begin marker, or an early result=FAIL, so an in-guest
    # failure surfaces its reason immediately instead of hanging to the timeout.
    idx = con.expect([begin, "AUDIO-SELFTEST result=FAIL"], timeout=600)
    if idx == 1:
        con.expect(r"\r?\n", timeout=10)
        pytest.fail(f"in-guest self-check failed (result=FAIL{con.before})")
    con.expect(end, timeout=600)
    try:
        wav = base64.b64decode(_reassemble_b64(con.before), validate=True)
    except binascii.Error as e:
        pytest.fail(f"could not decode {begin} base64 from console: {e}")
    assert len(wav) > 128, f"{begin}: recovered WAV too small ({len(wav)} bytes)"
    return wav


def _assert_tone(wav_bytes, freq, work_dir, name):
    wav_path = os.path.join(work_dir, name)
    with open(wav_path, "wb") as f:
        f.write(wav_bytes)
    proc = subprocess.run(
        [sys.executable, _GOERTZEL, wav_path, str(freq)],
        capture_output=True, text=True,
    )
    sys.stdout.write(proc.stdout)
    sys.stderr.write(proc.stderr)
    assert proc.returncode == 0, f"{name}: no dominant {freq} Hz peak"


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
    banner_tag = _login(con, qemu_target.boot_markers())
    # The boot banner must carry the build-under-test version (the audio image is
    # the same one; a mismatch means we booted the wrong slot/artifact).
    assert banner_tag == expected_tag, (
        f"boot banner version {banner_tag!r} != expected {expected_tag!r}"
    )

    # Push the self-check into the guest as base64 (one line, no quoting hazards).
    with open(_SELFCHECK, "rb") as f:
        sc_b64 = base64.b64encode(f.read()).decode()
    _run(con, f"printf '%s' '{sc_b64}' | base64 -d > /tmp/sc.sh", timeout=60)

    # Run it. It brings up the services/node, records the RX tone, plays+captures
    # the TX tone, and streams both WAVs between B64 markers. Generous TCG timeout.
    con.sendline("sh /tmp/sc.sh")

    rx_wav = _capture_wav(con, "AUDIO-WAV-B64-BEGIN", "AUDIO-WAV-B64-END")
    tx_wav = _capture_wav(con, "AUDIO-TXWAV-B64-BEGIN", "AUDIO-TXWAV-B64-END")

    con.expect(["AUDIO-SELFTEST result=PASS", "AUDIO-SELFTEST result=FAIL"], timeout=60)
    assert "FAIL" not in con.after, f"in-guest self-check failed: {con.after}{con.before[:200]!r}"

    # Host-side FFT verdicts: RX tap must be a clean 1 kHz sine; the TX tone routed
    # through oe5xrx.slot1.tx and captured off the reverse cable must be 1500 Hz.
    _assert_tone(rx_wav, 1000, qemu_target.work_dir, "rx.wav")
    _assert_tone(tx_wav, 1500, qemu_target.work_dir, "tx.wav")
