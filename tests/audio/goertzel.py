#!/usr/bin/env python3
"""Single-bin tone detector — the FFT half of the Spec 0 §8 known-tone assertion.

Runs on the HOST (not in the image) so the guest needs no Python/numpy: the guest
records ~0.5 s off the oe5xrx.slot1 PipeWire node with pw-record and ships the WAV
over serial as base64; this decodes it and confirms a 1 kHz sine dominates.

Pure stdlib (struct/math), parses the WAV container by hand — no `wave` module,
whose stdlib packaging (and the removed `chunk` dependency) varies across Python
versions. Exit 0 = target tone is the clear spectral peak; non-zero otherwise.

Usage: goertzel.py <file.wav> [target_hz]   (default target 1000 Hz)
"""
from __future__ import annotations

import math
import struct
import sys


def _read_wav(path: str):
    """Minimal PCM WAV reader → (samples[int] of channel 0, rate). 16-bit LE."""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE file")
    pos = 12
    fmt = None
    pcm = None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        (csz,) = struct.unpack_from("<I", data, pos + 4)
        body = data[pos + 8:pos + 8 + csz]
        if cid == b"fmt ":
            audio_fmt, channels, rate, _byterate, _align, bits = struct.unpack_from(
                "<HHIIHH", body, 0
            )
            fmt = (audio_fmt, channels, rate, bits)
        elif cid == b"data":
            pcm = body
        pos += 8 + csz + (csz & 1)  # chunks are word-aligned
    if fmt is None or pcm is None:
        raise ValueError("missing fmt/data chunk")
    audio_fmt, channels, rate, bits = fmt
    # 1 = WAVE_FORMAT_PCM, 0xFFFE = WAVE_FORMAT_EXTENSIBLE (still integer PCM as
    # written by arecord/pw-record). Anything else (float, ADPCM, …) would be
    # misread as int16 samples and give a bogus verdict, so reject it.
    if audio_fmt not in (1, 0xFFFE):
        raise ValueError(f"expected PCM WAV (fmt 1/0xFFFE), got fmt {audio_fmt}")
    if bits != 16:
        raise ValueError(f"expected 16-bit PCM, got {bits}-bit")
    total = len(pcm) // 2
    allsamples = struct.unpack_from("<%dh" % total, pcm, 0)
    ch0 = list(allsamples[0::channels]) if channels > 1 else list(allsamples)
    return ch0, rate


def goertzel_power(samples, rate: int, freq: float) -> float:
    """Normalised Goertzel power (magnitude²) at `freq`."""
    n = len(samples)
    if n == 0:
        return 0.0
    k = int(0.5 + (n * freq) / rate)
    omega = (2.0 * math.pi * k) / n
    coeff = 2.0 * math.cos(omega)
    s_prev = s_prev2 = 0.0
    for x in samples:
        s = x + coeff * s_prev - s_prev2
        s_prev2, s_prev = s_prev, s
    power = s_prev2 * s_prev2 + s_prev * s_prev - coeff * s_prev * s_prev2
    return power / (n * n)


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: goertzel.py <file.wav> [target_hz]", file=sys.stderr)
        return 2
    path = sys.argv[1]
    target = float(sys.argv[2]) if len(sys.argv) > 2 else 1000.0

    samples, rate = _read_wav(path)
    # Reject an out-of-range target: <=0 or >= Nyquist would alias (or, at the
    # extremes, produce a spurious peak). The caller picks the tone, so this is a
    # guard against a mis-invocation, not expected input.
    if not 0 < target < rate / 2:
        print(f"FAIL target {target:.0f} Hz out of range (0, {rate / 2:.0f})", file=sys.stderr)
        return 2
    if len(samples) < rate // 20:  # < 50 ms is too short to trust
        print(f"FAIL too few samples ({len(samples)} @ {rate} Hz)", file=sys.stderr)
        return 1

    # Absolute energy floor. A near-silent capture has ~0 power in every bin,
    # which makes max_ref ~ 0 and the ratio blow up to +inf -> a spurious PASS.
    # Require real signal energy (rms well above the noise floor of a 16-bit
    # capture) before trusting any peak. 50/32767 ≈ 0.15 % FS is generous.
    rms = (sum(x * x for x in samples) / len(samples)) ** 0.5
    if rms < 50.0:
        print(f"FAIL near-silent capture (rms={rms:.1f} < 50)", file=sys.stderr)
        return 1

    refs = [target / 4, target / 2, target * 1.5, target * 2, target * 3]
    refs = [f for f in refs if 0 < f < rate / 2]

    p_target = goertzel_power(samples, rate, target)
    p_refs = {f: goertzel_power(samples, rate, f) for f in refs}
    max_ref = max(p_refs.values()) if p_refs else 0.0

    ratio = (p_target / max_ref) if max_ref > 0 else float("inf")
    print(f"rate={rate} n={len(samples)} rms={rms:.0f} p({target:.0f})={p_target:.3e} "
          f"max_ref={max_ref:.3e} ratio={ratio:.1f}")
    for f, p in sorted(p_refs.items()):
        print(f"  ref {f:7.1f} Hz -> {p:.3e}")

    # A clean sine puts essentially all energy in the target bin; require the
    # target to beat every off-frequency probe by a wide margin.
    if ratio >= 10.0:
        print(f"PASS {target:.0f} Hz tone detected (peak ratio {ratio:.1f}x, rms {rms:.0f})")
        return 0
    print(f"FAIL no dominant {target:.0f} Hz peak (ratio {ratio:.1f}x < 10)", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
