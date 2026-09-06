#!/bin/sh
# OE5XRX Session-E agent-side audio E2E self-check (Spec 0 §7 row E / §8), runs
# INSIDE the guest. Unlike tests/audio/audio_selfcheck.sh (Session A: proves the
# raw PipeWire/ALSA substrate), this drives the AGENT's own audio engine:
#
#   python -m station_agent selftest audio --slot N
#
# which taps the sim 1 kHz shim on oe5xrx.slotN through the agent's RouterBackend +
# Opus bridge (encode->decode roundtrip) and asserts the tone with its pure-Python
# Goertzel probe (RX), then injects a distinct 1500 Hz tone into oe5xrx.slotN.tx and
# verifies it on the aloop reverse-cable tap (TX). The agent's Goertzel verdict AND
# the dominance ratio it logs ARE the FFT proof — the guest needs no host round-trip.
#
# Proves Session A (image PipeWire + snd-aloop tone shim) and Session B (agent audio
# engine) end-to-end on the agent side against the real PipeWire in the merged image.
# The same command runs on the CM4 bench (--slot 3) against a real SA818 / RF tone.
set -u

export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run/pipewire}"
SLOT="${SLOT:-1}"
DURATION="${DURATION:-2}"
TXFREQ="${TXFREQ:-1500}"

# Quiet the kernel console so printk lines can't splice into the agent's log output
# on the shared serial console; restore on every exit path.
prev_printk="$(awk '{print $1}' /proc/sys/kernel/printk 2>/dev/null || true)"
restore_printk() {
    [ -n "$prev_printk" ] || return 0
    echo "$prev_printk" > /proc/sys/kernel/printk 2>/dev/null || true
}
trap restore_printk EXIT
trap 'restore_printk; exit 130' INT TERM
echo 1 > /proc/sys/kernel/printk 2>/dev/null || true

dump_diag() {
    echo "--- diag: systemctl ---"
    systemctl --no-pager -l status oe5xrx-pipewire oe5xrx-wireplumber oe5xrx-sim-audio station-agent 2>&1 | sed 's/^/diag: /' | head -100
    echo "--- diag: wpctl status ---"
    timeout 8 wpctl status 2>&1 | sed 's/^/diag: /' | head -100
    echo "--- diag: pw-cli ls Node ---"
    timeout 8 pw-cli ls Node 2>&1 | sed 's/^/diag: /' | head -140
    echo "--- diag: /proc/asound/cards ---"
    sed 's/^/diag: /' /proc/asound/cards 2>&1
    echo "--- diag end ---"
}

# 1) Wait for the sim audio substrate to be fully up. oe5xrx-sim-audio only reaches
# 'active' AFTER WirePlumber has created the oe5xrx.slot1 node and the 1 kHz tone
# shim is running (see sim-audio.sh) — so this one check gates RX readiness.
_i=0
while :; do
    s="$(systemctl is-active oe5xrx-sim-audio 2>/dev/null || true)"
    p="$(systemctl is-active oe5xrx-pipewire 2>/dev/null || true)"
    w="$(systemctl is-active oe5xrx-wireplumber 2>/dev/null || true)"
    [ "$s" = active ] && [ "$p" = active ] && [ "$w" = active ] && break
    _i=$((_i + 1))
    if [ "$_i" -ge 90 ]; then
        dump_diag
        echo "AGENT-AUDIO-E2E result=FAIL reason=substrate_not_active(sim=$s pw=$p wp=$w)"
        exit 0
    fi
    sleep 1
done
echo "AGENT-AUDIO-E2E substrate=ready sim=$s pw=$p wp=$w"

# 2) Free the field: station-agent runs as a service. Even with audio disabled in
# the seeded config it must not contend for the TX sink while the selftest owns the
# audio path (Session-E contention note). Stopping it is harmless — the selftest is
# a standalone CLI invocation of the same module.
systemctl stop station-agent 2>/dev/null || true

# 3) Warm the GStreamer plugin registry so the selftest's short-timeout gst-launch
# captures don't race a cold first-run registry build under QEMU/TCG.
gst-inspect-1.0 fakesrc >/dev/null 2>&1 || true

# 4) Run the agent's own audio selftest. Merge stderr (where the agent logs its
# Goertzel verdict + FFT dominance ratio) into stdout so the CI console captures it.
echo "AGENT-AUDIO-E2E-OUTPUT-BEGIN"
python3 -m station_agent selftest audio --slot "$SLOT" --duration "$DURATION" --tx-freq "$TXFREQ" 2>&1
rc=$?
echo "AGENT-AUDIO-E2E-OUTPUT-END"

if [ "$rc" -eq 0 ]; then
    echo "AGENT-AUDIO-E2E result=PASS slot=$SLOT rc=$rc"
else
    dump_diag
    echo "AGENT-AUDIO-E2E result=FAIL reason=selftest_rc=$rc slot=$SLOT"
fi
