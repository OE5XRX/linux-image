#!/bin/sh
# OE5XRX audio okay-gate self-check (Spec 0 §7-A / §8), runs INSIDE the guest.
#
# Verifies the Session-A image foundation and captures the sim tone for the
# host-side FFT verdict:
#   1. system PipeWire + WirePlumber services are active,
#   2. the GStreamer bridge elements (opusenc/opusdec/pipewiresrc/pipewiresink)
#      are present,
#   3. WirePlumber named EXACTLY ONE slot node oe5xrx.slot1,
#   4. record off oe5xrx.slot1 and emit it as base64 for the host to FFT.
#
# The tone is self-contained (pure GStreamer sine, §10 decision D1). The final
# 1 kHz verdict is computed on the host by goertzel.py — the guest ships no
# Python for it. Also runnable standalone on the CM4 bench.
set -u

export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run/pipewire}"
NODE="${NODE:-oe5xrx.slot1}"
REC_SECS="${REC_SECS:-1.5}"
REC_RATE="${REC_RATE:-16000}"
WAV="${WAV:-/tmp/oe5xrx-rx.wav}"
# Require at least ~0.4 s of captured s16 mono (rate*2*0.4 bytes); a truncated
# capture (slow pw-record link-up under TCG) must fail loud, not feed a
# confusing host-side FFT miss.
MIN_BYTES="${MIN_BYTES:-12800}"

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
for el in opusenc opusdec pipewiresrc pipewiresink; do
    gst-inspect-1.0 "$el" >/dev/null 2>&1 || fail "no_$el"
done
echo "AUDIO-CHECK gst=ok opusenc,opusdec,pipewiresrc,pipewiresink present"

# 3) exactly one slot node named by WirePlumber -------------------------------
# Anchor so "oe5xrx.slot1" does not also count the TX sink "oe5xrx.slot1.tx"
# (a real-HW node; would otherwise false-trip the ambiguity guard). Match the
# name only when NOT followed by a further '.'.
node_re="$(printf '%s' "$NODE" | sed 's/[.]/\\./g')([^.]|\$)"
_i=0
while :; do
    count="$(wpctl status 2>/dev/null | grep -cE "$node_re" || true)"
    [ "$count" -ge 1 ] && break
    _i=$((_i + 1))
    [ "$_i" -ge 60 ] && { wpctl status 2>&1 | sed 's/^/wpctl: /'; fail "node_${NODE}_absent"; }
    sleep 1
done
# A duplicate name (e.g. both aloop capture ends matched) means the recording
# target is ambiguous — fail loudly rather than record the wrong (silent) end.
if [ "$count" -gt 1 ]; then
    wpctl status 2>&1 | sed 's/^/wpctl: /'
    fail "node_${NODE}_ambiguous(count=$count)"
fi
echo "AUDIO-CHECK node=$NODE present count=$count"

# 4) record the tone off the slot node ---------------------------------------
# Quiet the kernel console so printk lines can't splice into the base64 blob we
# stream over the shared serial console. Restore afterwards.
prev_printk="$(awk '{print $1}' /proc/sys/kernel/printk 2>/dev/null || true)"
echo 1 > /proc/sys/kernel/printk 2>/dev/null || true

# pw-record has no duration flag; bound it with timeout. Capture stderr so a
# flag/format rejection is diagnosable instead of a silent empty recording.
rm -f "$WAV"
timeout "$REC_SECS" pw-record --target "$NODE" --channels 1 --rate "$REC_RATE" --format s16 "$WAV" 2>/tmp/pw-record.err || true

if [ -n "$prev_printk" ]; then
    echo "$prev_printk" > /proc/sys/kernel/printk 2>/dev/null || true
fi

if [ ! -s "$WAV" ]; then
    sed 's/^/pw-record: /' /tmp/pw-record.err 2>/dev/null
    fail "empty_recording"
fi
bytes="$(wc -c < "$WAV")"
if [ "$bytes" -lt "$MIN_BYTES" ]; then
    sed 's/^/pw-record: /' /tmp/pw-record.err 2>/dev/null
    fail "short_recording(bytes=$bytes min=$MIN_BYTES)"
fi
echo "AUDIO-CHECK recorded bytes=$bytes node=$NODE rate=$REC_RATE"

# 5) ship the WAV to the host for the FFT verdict ----------------------------
# One tagged line; the host keeps only B64:-prefixed content between the markers
# so any stray console line is discarded wholesale rather than merged byte-wise.
echo "AUDIO-WAV-B64-BEGIN"
printf 'B64:%s\n' "$(base64 -w0 "$WAV" 2>/dev/null || base64 "$WAV" | tr -d '\n')"
echo "AUDIO-WAV-B64-END"

# In-guest checks (1-3) passed; the host computes the final 1 kHz FFT verdict.
echo "AUDIO-SELFTEST result=PASS checks=services,gst,node,record"
