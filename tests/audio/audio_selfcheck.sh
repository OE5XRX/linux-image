#!/bin/sh
# OE5XRX audio okay-gate self-check (Spec 0 §7-A / §8), runs INSIDE the guest.
#
# Verifies the Session-A image foundation and captures the sim tone for the
# host-side FFT verdict:
#   1. system PipeWire + WirePlumber services are active,
#   2. the GStreamer bridge elements (opusenc, pipewiresrc) are present,
#   3. WirePlumber named the slot1 node oe5xrx.slot1,
#   4. record ~0.6 s off oe5xrx.slot1 and emit it as base64 for the host to FFT.
#
# Emits parseable markers; the ota-integration test (or a human) reads them. The
# final 1 kHz verdict is computed on the host by goertzel.py — the guest ships no
# Python for it. Also runnable standalone on the CM4 bench.
set -u

export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run/pipewire}"
NODE="${NODE:-oe5xrx.slot1}"
REC_SECS="${REC_SECS:-0.6}"
REC_RATE="${REC_RATE:-16000}"
WAV="${WAV:-/tmp/oe5xrx-rx.wav}"

fail() { echo "AUDIO-SELFTEST result=FAIL reason=$1"; exit 1; }

# 1) services -----------------------------------------------------------------
_i=0
while :; do
    a="$(systemctl is-active oe5xrx-pipewire 2>/dev/null || true)"
    b="$(systemctl is-active oe5xrx-wireplumber 2>/dev/null || true)"
    [ "$a" = active ] && [ "$b" = active ] && break
    _i=$((_i + 1)); [ "$_i" -ge 60 ] && fail "services_not_active(pipewire=$a wireplumber=$b)"
    sleep 1
done
echo "AUDIO-CHECK services=active pipewire=$a wireplumber=$b"

# 2) gstreamer bridge elements ------------------------------------------------
gst-inspect-1.0 opusenc    >/dev/null 2>&1 || fail "no_opusenc"
gst-inspect-1.0 opusdec    >/dev/null 2>&1 || fail "no_opusdec"
gst-inspect-1.0 pipewiresrc  >/dev/null 2>&1 || fail "no_pipewiresrc"
gst-inspect-1.0 pipewiresink >/dev/null 2>&1 || fail "no_pipewiresink"
echo "AUDIO-CHECK gst=ok opusenc,opusdec,pipewiresrc,pipewiresink present"

# 3) slot node named by WirePlumber ------------------------------------------
_i=0
while :; do
    if wpctl status 2>/dev/null | grep -qF "$NODE"; then break; fi
    _i=$((_i + 1)); [ "$_i" -ge 60 ] && { wpctl status 2>&1 | sed 's/^/wpctl: /'; fail "node_${NODE}_absent"; }
    sleep 1
done
echo "AUDIO-CHECK node=$NODE present"

# 4) record the tone off the slot node ---------------------------------------
# pw-record has no duration flag; bound it with timeout. s16 mono keeps the
# base64 blob small enough to stream over the serial console reliably.
rm -f "$WAV"
timeout "$REC_SECS" pw-record --target "$NODE" --channels 1 --rate "$REC_RATE" --format s16 "$WAV" 2>/dev/null || true
[ -s "$WAV" ] || fail "empty_recording"
bytes="$(wc -c < "$WAV")"
echo "AUDIO-CHECK recorded bytes=$bytes node=$NODE rate=$REC_RATE"

# 5) ship the WAV to the host for the FFT verdict ----------------------------
echo "AUDIO-WAV-B64-BEGIN"
base64 -w0 "$WAV" 2>/dev/null || base64 "$WAV"
echo
echo "AUDIO-WAV-B64-END"

# In-guest checks (1-3) passed; the host computes the final 1 kHz FFT verdict.
echo "AUDIO-SELFTEST result=PASS checks=services,gst,node,record"