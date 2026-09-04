#!/bin/sh
# OE5XRX audio okay-gate self-check (Spec 0 §7-A / §8), runs INSIDE the guest.
#
# Verifies the Session-A image foundation and captures the sim tones for the
# host-side FFT verdict (bidirectional, Spec 0 §8):
#   1. system PipeWire + WirePlumber services are active,
#   2. the GStreamer bridge elements (opusenc/opusdec/pipewiresrc/pipewiresink)
#      are present,
#   3. WirePlumber named EXACTLY ONE RX node oe5xrx.slot1,
#   4. RX: record the 1 kHz tone off oe5xrx.slot1 (cable A tap),
#   5. TX: play a distinct 1500 Hz tone into oe5xrx.slot1.tx and capture it off
#      the reverse-cable dev0 tap — proves mic->TX works in sim for Session B.
# Both WAVs are shipped as base64; the host computes the RX(1 kHz)+TX(1500 Hz)
# Goertzel verdicts (goertzel.py) — the guest ships no Python. Runnable
# standalone on the CM4 bench too.
set -u

export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run/pipewire}"
# RX source node + the 8 kHz mono the sim now uses (Spec 0 §8/§12). Rate travels
# in the WAV header, so the host FFT is rate-agnostic.
NODE="${NODE:-oe5xrx.slot1}"
# Integer seconds only — passed to `timeout`, and BusyBox's timeout (minimal
# images) rejects fractional intervals ("invalid time interval"), which would
# make the RX capture fail immediately.
REC_SECS="${REC_SECS:-2}"
REC_RATE="${REC_RATE:-8000}"
REC_CHANNELS="${REC_CHANNELS:-1}"
WAV="${WAV:-/tmp/oe5xrx-rx.wav}"
# TX sink node + the raw dev0-capture tap (cable B) the TX tone lands on. A
# DISTINCT frequency (1500 Hz) so the TX Goertzel can't be fooled by RX bleed.
ALOOP_ID="${ALOOP_ID:-oe5xrxslot1}"
TX_NODE="${TX_NODE:-oe5xrx.slot1.tx}"
TX_TAP="${TX_TAP:-hw:${ALOOP_ID},0,0}"
TX_FREQ="${TX_FREQ:-1500}"
TX_SECS="${TX_SECS:-1}"
# The aloop playback substream that oe5xrx.slot1.tx (dev1 playback) drives; we
# wait for it to reach RUNNING before opening the capture tap, rather than a
# blind sleep that races pipewiresink link-up under TCG.
TX_PCM_STATUS="${TX_PCM_STATUS:-/proc/asound/${ALOOP_ID}/pcm1p/sub0/status}"
TXWAV="${TXWAV:-/tmp/oe5xrx-tx.wav}"
# Require at least ~0.4 s of captured s16 mono (rate*2*0.4 bytes); a truncated
# capture (slow pw-record link-up under TCG) must fail loud, not feed a
# confusing host-side FFT miss. 0.4 s @ 8 kHz mono s16 = 6400 bytes.
MIN_BYTES="${MIN_BYTES:-6400}"

fail() { echo "AUDIO-SELFTEST result=FAIL reason=$1"; exit 1; }

# Emit a WAV to the host as one B64:-tagged line between unique markers; the host
# keeps only B64: lines so a stray console line is dropped wholesale, not merged.
emit_wav() {  # $1=wav  $2=begin-marker  $3=end-marker
    echo "$2"
    printf 'B64:%s\n' "$(base64 -w0 "$1" 2>/dev/null || base64 "$1" | tr -d '\n')"
    echo "$3"
}

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
# (a real-HW node; would otherwise false-trip the ambiguity guard). Treat NODE as
# a LITERAL node name — escape ALL ERE metacharacters, not just '.', so an
# overridden NODE can't inject regex specials — then require it not be followed by
# a further '.'.
node_esc="$(printf '%s' "$NODE" | sed 's/[][^$.*+?(){}|\\]/\\&/g')"
node_re="${node_esc}([^.]|\$)"
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

# Quiet the kernel console for the whole record+stream window so printk lines
# can't splice into the base64 blobs on the shared serial console. A trap restores
# the previous loglevel on EVERY exit path (normal, fail-via-exit, INT/TERM) — an
# interrupted run must never leave the console permanently quiet (matters for
# standalone/bench use) — and it keeps printk low until AFTER both the RX and TX
# base64 blobs have streamed.
prev_printk="$(awk '{print $1}' /proc/sys/kernel/printk 2>/dev/null || true)"
restore_printk() {
    [ -n "$prev_printk" ] || return 0
    echo "$prev_printk" > /proc/sys/kernel/printk 2>/dev/null || true
}
trap restore_printk EXIT
trap 'restore_printk; exit 130' INT TERM
echo 1 > /proc/sys/kernel/printk 2>/dev/null || true

# 4) RX gate: record the 1 kHz tone off the slot RX node ----------------------
# pw-record has no duration flag; bound it with timeout. Capture stderr so a
# flag/format rejection is diagnosable instead of a silent empty recording.
rm -f "$WAV"
timeout "$REC_SECS" pw-record --target "$NODE" --channels "$REC_CHANNELS" --rate "$REC_RATE" --format s16 "$WAV" 2>/tmp/pw-record.err || true

if [ ! -s "$WAV" ]; then
    sed 's/^/pw-record: /' /tmp/pw-record.err 2>/dev/null
    fail "empty_rx_recording"
fi
bytes="$(wc -c < "$WAV")"
if [ "$bytes" -lt "$MIN_BYTES" ]; then
    sed 's/^/pw-record: /' /tmp/pw-record.err 2>/dev/null
    fail "short_rx_recording(bytes=$bytes min=$MIN_BYTES)"
fi
echo "AUDIO-CHECK rx recorded bytes=$bytes node=$NODE rate=$REC_RATE"
emit_wav "$WAV" "AUDIO-WAV-B64-BEGIN" "AUDIO-WAV-B64-END"

# 5) TX gate: play a DISTINCT 1500 Hz tone into the TX sink and capture it off
# the reverse-cable tap (dev0 capture) ----------------------------------------
# Start the tone into oe5xrx.slot1.tx (PipeWire resumes dev1 playback), give the
# aloop cable time to prime, then raw-capture dev0 capture. gst pipewiresink
# targets the sink node by name; the raw arecord owns dev0 capture (WirePlumber
# disabled that PipeWire node, so no contention).
rm -f "$TXWAV"
gst-launch-1.0 -q \
    audiotestsrc is-live=true wave=sine freq="$TX_FREQ" ! \
    audioconvert ! audioresample ! \
    "audio/x-raw,format=S16LE,rate=${REC_RATE},channels=${REC_CHANNELS}" ! \
    pipewiresink "target-object=${TX_NODE}" sync=false > /tmp/tx-tone.log 2>&1 &
tx_pid=$!
# Wait until PipeWire has actually RESUMED the aloop playback end (reverse cable
# live) before opening the capture tap — otherwise the two ends can negotiate
# mismatched params or the tap records silence. Bounded (~10 s); if it never
# runs we still record (the host FFT then fails loudly, not silently).
_i=0
while [ "$_i" -lt 100 ]; do
    grep -q "state: RUNNING" "$TX_PCM_STATUS" 2>/dev/null && break
    _i=$((_i + 1)); sleep 0.1
done
arecord -t wav -D "$TX_TAP" -f S16_LE -r "$REC_RATE" -c "$REC_CHANNELS" -d "$TX_SECS" "$TXWAV" 2>/tmp/arecord.err || true
kill "$tx_pid" 2>/dev/null || true
# printk is restored by the EXIT trap AFTER the TX blob streams below — do not
# restore here, or kernel logs could splice into the TX base64.

if [ ! -s "$TXWAV" ]; then
    sed 's/^/arecord: /' /tmp/arecord.err 2>/dev/null
    sed 's/^/tx-tone: /' /tmp/tx-tone.log 2>/dev/null
    fail "empty_tx_recording"
fi
txbytes="$(wc -c < "$TXWAV")"
if [ "$txbytes" -lt "$MIN_BYTES" ]; then
    sed 's/^/arecord: /' /tmp/arecord.err 2>/dev/null
    fail "short_tx_recording(bytes=$txbytes min=$MIN_BYTES)"
fi
echo "AUDIO-CHECK tx recorded bytes=$txbytes sink=$TX_NODE tap=$TX_TAP freq=$TX_FREQ"
emit_wav "$TXWAV" "AUDIO-TXWAV-B64-BEGIN" "AUDIO-TXWAV-B64-END"

# In-guest checks passed; the host computes the final RX(1 kHz)+TX(1500 Hz) FFT.
echo "AUDIO-SELFTEST result=PASS checks=services,gst,node,rx,tx"
