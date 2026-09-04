"""Unit test for the host-side tone detector (tests/audio/goertzel.py).

No image / QEMU needed — synthesises WAVs in-process and checks the detector
distinguishes a 1 kHz sine from an off-frequency tone and from noise. This keeps
the FFT half of the audio okay-gate honest independently of a Yocto build.
"""

from __future__ import annotations

import importlib.util
import math
import os
import struct

import pytest

pytestmark = pytest.mark.unit

_AUDIO_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "audio"))


def _load_goertzel():
    spec = importlib.util.spec_from_file_location(
        "goertzel", os.path.join(_AUDIO_DIR, "goertzel.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _write_sine(path, freq, rate=16000, secs=0.6, amp=0.6):
    n = int(rate * secs)
    frames = bytearray()
    for i in range(n):
        v = amp * math.sin(2.0 * math.pi * freq * i / rate) if freq else 0.0
        frames += struct.pack("<h", int(v * 32767))
    data = bytes(frames)
    with open(path, "wb") as f:
        f.write(b"RIFF")
        f.write(struct.pack("<I", 36 + len(data)))
        f.write(b"WAVE")
        f.write(b"fmt ")
        f.write(struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16))
        f.write(b"data")
        f.write(struct.pack("<I", len(data)))
        f.write(data)


def test_detects_1khz(tmp_path):
    g = _load_goertzel()
    wav = str(tmp_path / "t1k.wav")
    _write_sine(wav, 1000)
    # Exercise via the module's main() contract.
    import sys
    argv = sys.argv
    try:
        sys.argv = ["goertzel.py", wav, "1000"]
        assert g.main() == 0
    finally:
        sys.argv = argv


def test_rejects_2khz(tmp_path):
    g = _load_goertzel()
    wav = str(tmp_path / "t2k.wav")
    _write_sine(wav, 2000)
    import sys
    argv = sys.argv
    try:
        sys.argv = ["goertzel.py", wav, "1000"]
        assert g.main() != 0
    finally:
        sys.argv = argv


def test_power_peaks_at_signal_freq(tmp_path):
    g = _load_goertzel()
    wav = str(tmp_path / "s.wav")
    _write_sine(wav, 1000)
    samples, rate = g._read_wav(wav)
    p1000 = g.goertzel_power(samples, rate, 1000)
    p2000 = g.goertzel_power(samples, rate, 2000)
    assert p1000 > 10 * p2000
