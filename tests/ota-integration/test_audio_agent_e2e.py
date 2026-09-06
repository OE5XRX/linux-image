"""E — agent-side audio E2E okay-gate (Spec 0 §7 row E / §8, Tier 1).

Boots the built qemux86-64 image (with the audio-enabled station-agent pinned) and,
over the serial console, runs the AGENT's own audio self-check in the guest:

    python -m station_agent selftest audio --slot 1

This proves Session A (image PipeWire + snd-aloop 1 kHz tone shim + oe5xrx.slot1 /
oe5xrx.slot1.tx nodes) and Session B (agent RouterBackend + Opus bridge) end-to-end
on the AGENT side against the real PipeWire in the image — not just the raw substrate
that tests/audio/audio_selfcheck.sh (Session A's row-A gate) checks:

  * RX: the selftest taps oe5xrx.slot1 through the agent's Opus encode->decode
    roundtrip and asserts the 1 kHz shim survives (its pure-Python Goertzel FFT).
  * TX: the selftest injects a distinct 1500 Hz tone (Opus roundtrip) into
    oe5xrx.slot1.tx and verifies it on the aloop reverse-cable tap.

The agent's Goertzel verdict AND the FFT dominance ratio it logs ARE the proof; the
guest ships no WAVs and the host does no FFT. The self-check script
(tests/audio/agent_audio_selfcheck.sh) waits for the sim substrate, stops the
station-agent service to avoid TX contention, warms the gst registry, then runs the
selftest and prints its output between markers. Same command runs on the CM4 bench
(--slot 3) against a real SA818 / RF tone — the honesty rule's real-HW follow-up.
"""

from __future__ import annotations

import base64
import os
import re
import sys

import pexpect
import pytest

pytestmark = pytest.mark.qemu

_HERE = os.path.dirname(__file__)
_AUDIO_DIR = os.path.abspath(os.path.join(_HERE, "..", "audio"))
_SELFCHECK = os.path.join(_AUDIO_DIR, "agent_audio_selfcheck.sh")

_PROMPT = "OE5XRX-AGENT-AUDIO-SH> "


def _login(con, markers):
    """Log in as root over the serial console and pin a unique prompt.

    Mirrors test_audio.py's login: sync on a command's OUTPUT sentinel (not the echoed
    command), since terminal echo may be off.
    """
    con.expect(markers["banner_re"], timeout=900)
    banner_tag = con.match.group(1)
    con.expect(markers["login_re"], timeout=300)
    con.sendline("root")
    idx = con.expect(["Password:", r"root@[^#]*# ", r"# "], timeout=60)
    if idx == 0:
        con.sendline("")
        con.expect(r"# ", timeout=60)
    con.sendline(f"export PS1='{_PROMPT}'")
    con.sendline("echo SYNC-$?-READY")
    con.expect("SYNC-0-READY", timeout=30)
    con.expect(_PROMPT, timeout=30)
    return banner_tag


def _run(con, cmd, timeout=120):
    con.sendline(cmd)
    con.expect(_PROMPT, timeout=timeout)
    return con.before


def test_e_agent_audio_e2e(qemu_target, built_wic, expected_tag):
    import seed

    qemu_target.flash(built_wic)
    qemu_target.reset_ab_state()
    # The agent needs a config to boot cleanly to multi-user; reuse the OTA seed with
    # a dummy URL (no OTA server needed — the selftest is offline, local to the guest).
    key_pem = qemu_target.work_dir + "/device_key.pem"
    seed.gen_ed25519_key(key_pem)
    qemu_target.seed_config(seed.render_config_yaml("http://10.0.2.2:1/"), key_pem)

    con = qemu_target.power_on()
    banner_tag = _login(con, qemu_target.boot_markers())
    assert banner_tag == expected_tag, (
        f"boot banner version {banner_tag!r} != expected {expected_tag!r}"
    )

    # Push the self-check into the guest as base64 (one line, no quoting hazards).
    with open(_SELFCHECK, "rb") as f:
        sc_b64 = base64.b64encode(f.read()).decode()
    _run(con, f"printf '%s' '{sc_b64}' | base64 -d > /tmp/agent_sc.sh", timeout=60)

    # Run it. It waits for the sim audio substrate, stops the agent service, warms the
    # gst registry, runs `selftest audio`, and prints the agent's output (RX/TX Goertzel
    # verdicts + FFT dominance ratios) between the OUTPUT markers. Generous TCG timeout.
    con.sendline("sh /tmp/agent_sc.sh")

    try:
        con.expect("AGENT-AUDIO-E2E-OUTPUT-BEGIN", timeout=300)
    except pexpect.TIMEOUT:
        pytest.fail(
            "timed out before the selftest ran (substrate not ready?). "
            f"Console tail:\n{con.before[-4000:]}"
        )
    try:
        con.expect("AGENT-AUDIO-E2E-OUTPUT-END", timeout=300)
    except pexpect.TIMEOUT:
        pytest.fail(f"timed out during `selftest audio`. Console tail:\n{con.before[-4000:]}")
    selftest_output = con.before

    # Final verdict line printed by the wrapper after the output block.
    idx = con.expect(
        ["AGENT-AUDIO-E2E result=PASS", "AGENT-AUDIO-E2E result=FAIL"], timeout=120
    )
    verdict_tail = con.before

    # Surface the agent's own FFT evidence into the CI log regardless of pass/fail.
    sys.stdout.write("\n----- `station_agent selftest audio` guest output -----\n")
    sys.stdout.write(selftest_output)
    sys.stdout.write("\n-------------------------------------------------------\n")

    assert idx == 0, (
        "agent audio selftest FAILED in QEMU.\n"
        f"selftest output:\n{selftest_output}\n"
        f"wrapper diag/tail:\n{verdict_tail[-4000:]}"
    )

    # The agent's own end-to-end verdict + both FFT dominance verdicts must be present
    # in the captured output (proves RX 1 kHz through Opus AND TX 1500 Hz on the reverse
    # tap — not a false pass on a partial run).
    assert "selftest audio: PASS" in selftest_output, (
        f"agent selftest did not report PASS. Output:\n{selftest_output}"
    )
    assert "RX OK" in selftest_output, f"no RX OK verdict. Output:\n{selftest_output}"
    assert "TX OK" in selftest_output, f"no TX OK verdict. Output:\n{selftest_output}"

    # Assert the logged FFT dominance ratios clear the selftest's margin (>4x). The
    # agent logs e.g. "P(1000)/P(runner-up)=37.ytimes" — parse and re-check as a
    # host-side guard so a future logging change can't silently weaken the gate.
    ratios = [float(m) for m in re.findall(r"P\([0-9]+\)/P\(runner-up\)=([0-9.]+)x", selftest_output)]
    assert len(ratios) == 2, (
        f"expected 2 FFT dominance ratios (RX+TX), got {ratios}. Output:\n{selftest_output}"
    )
    assert all(r > 4.0 for r in ratios), f"FFT dominance ratio below margin: {ratios}"
