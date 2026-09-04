#!/bin/sh
# OE5XRX sim audio substrate (qemux86-64/Proxmox, Spec 0 §8).
#
# The QEMU guest has no SA818 and no UAC2 audio device, so audio is emulated
# INSIDE the guest with snd-aloop (ALSA kernel loopback) — the audio analog of
# the native_sim control pty. This script:
#   1. loads snd-aloop with a stable card id (ALOOP_ID) so udev tags it slot1
#      (ATTRS{id}, see 90-oe5xrx-slots.rules) and WirePlumber renames its capture
#      node to the canonical oe5xrx.slot1 (see 51-oe5xrx-slot-naming.conf);
#   2. drives a continuous 1 kHz sine into the loopback PLAYBACK side, which
#      snd-aloop cross-wires to the CAPTURE side — so the agent's RX tap reads a
#      known tone (FFT peak @ 1 kHz), identical assertion in sim and on the bench.
#
# The tone is self-contained (pure GStreamer sine, §10 decision D1): a bare tone
# has no firmware coupling, unlike the SA818 control emulator which co-versions
# with native_sim. No QEMU audio backend is ever needed — the agent Opus-encodes
# and ships the tone over the network, so audio leaves the guest as packets.
#
# Overridable for host testing.
set -eu

ALOOP_ID="${ALOOP_ID:-oe5xrxslot1}"
ALOOP_INDEX="${ALOOP_INDEX:-7}"
TONE_FREQ="${TONE_FREQ:-1000}"
# 8 kHz mono S16_LE mirrors the real UAC2 FM module (Spec 0 §8/§12) and makes the
# aloop cable run at 8 kHz, so the PipeWire graph (48 kHz) exercises the real
# 8 k->48 k resample path. Both aloop cable ends must agree on rate/format, so the
# oe5xrx.slot1 RX node is pinned to the same 8 k mono S16LE (51-oe5xrx-slot-naming).
TONE_RATE="${TONE_RATE:-8000}"
TONE_CHANNELS="${TONE_CHANNELS:-1}"
# card id, pcm device 0, subdevice 0 = the playback side snd-aloop cross-wires to
# the capture of pcm device 1 (the RX tap PipeWire reads as oe5xrx.slot1).
TONE_SINK="${TONE_SINK:-hw:${ALOOP_ID},0,0}"
# The PipeWire node WirePlumber creates for this card once it enumerates it.
export PIPEWIRE_RUNTIME_DIR="${PIPEWIRE_RUNTIME_DIR:-/run/pipewire}"
SLOT_NODE="${SLOT_NODE:-oe5xrx.slot1}"

running=1
TONE_PID=""

cleanup() {
    if [ -n "$TONE_PID" ]; then
        kill "$TONE_PID" 2>/dev/null || true
        TONE_PID=""
    fi
}
on_term() { running=0; cleanup; }
trap on_term TERM INT
trap cleanup EXIT

# Load the loopback with a stable id (idempotent — tolerate an already-loaded
# module across a service restart).
if [ ! -d "/proc/asound/${ALOOP_ID}" ]; then
    modprobe snd-aloop index="${ALOOP_INDEX}" id="${ALOOP_ID}" pcm_substreams=1
fi

_i=0
while [ ! -d "/proc/asound/${ALOOP_ID}" ]; do
    _i=$((_i + 1))
    [ "$_i" -ge 50 ] && { echo "sim-audio: snd-aloop card '${ALOOP_ID}' never appeared" >&2; exit 1; }
    sleep 0.1
done
echo "sim-audio: snd-aloop card '${ALOOP_ID}' ready (index ${ALOOP_INDEX})" >&2

# CRITICAL ORDERING: wait for WirePlumber to enumerate the (still-free) aloop card
# and create the oe5xrx.slot1 node BEFORE we grab the card with the raw tone shim.
# The SPA ALSA udev backend needs to open the card to enumerate it; if the shim
# already holds a PCM the card reports "Device or resource busy" and WirePlumber
# defers it forever -> no PipeWire node is ever created. Once WirePlumber has the
# device, the shim opening dev0-playback coexists fine (different PCM substreams).
if command -v pw-cli >/dev/null 2>&1; then
    _j=0
    while ! pw-cli ls Node 2>/dev/null | grep -q "\"${SLOT_NODE}\""; do
        _j=$((_j + 1))
        if [ "$_j" -ge 60 ]; then
            echo "sim-audio: WARNING ${SLOT_NODE} node absent after 60s; starting tone anyway" >&2
            break
        fi
        sleep 1
    done
    [ "$_j" -lt 60 ] && echo "sim-audio: ${SLOT_NODE} node present after ${_j}s — starting tone" >&2
fi

# Continuous 1 kHz sine into the loopback playback side. Restart the shim if it
# ever exits while we are still running: PipeWire's ALSA monitor may briefly
# probe the card at hotplug and transiently hold the device, so a short backoff
# lets alsasink acquire it cleanly.
while [ "$running" = 1 ]; do
    gst-launch-1.0 -q \
        audiotestsrc is-live=true wave=sine freq="${TONE_FREQ}" ! \
        audioconvert ! audioresample ! \
        "audio/x-raw,format=S16LE,rate=${TONE_RATE},channels=${TONE_CHANNELS}" ! \
        alsasink device="${TONE_SINK}" sync=true &
    TONE_PID=$!
    echo "sim-audio: ${TONE_FREQ} Hz tone -> ${TONE_SINK} (pid ${TONE_PID})" >&2
    wait "$TONE_PID" || true
    TONE_PID=""
    [ "$running" = 1 ] && { echo "sim-audio: tone shim exited, retrying in 2s" >&2; sleep 2; }
done
