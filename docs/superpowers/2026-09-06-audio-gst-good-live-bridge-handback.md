# Handback — Audio live-bridge GStreamer plugins fix (S2, linux-image)

**Date:** 2026-09-06
**Branch:** `fix/audio-gst-good-rtp-udp-main` (off `origin/main`)
**PR:** _(opened from this branch — see below)_
**Spec:** `station-manager/docs/superpowers/specs/2026-09-03-audio-subsystem-design.md` (§8)

Autonomous fix session S2. Fixes one image bug (RC#1) + one CI-coverage gap (FIX#4)
surfaced by a live integration test of the audio subsystem (Sessions A–E in main).

## RC#1 — missing GStreamer plugins killed the live Opus bridge (BLOCKER)

**Symptom (measured live on a QEMU station):** `gst-inspect-1.0` could not find
`rtpopuspay`, `rtpopusdepay`, `udpsink`, `udpsrc` (only opus/pipewire elements were in
the image). The agent's live Opus bridge (`station_agent/audio/opus_bridge.py`) is an
RTP-over-UDP loopback:

```
RX (tap module → WS):   pipewiresrc ! audioconvert ! audioresample ! opusenc ! rtpopuspay ! udpsink
TX (WS → inject module): udpsrc ! rtpjitterbuffer ! rtpopusdepay ! opusdec ! audioconvert ! audioresample ! pipewiresink
```

With the rtp/udp/rtpmanager elements absent, the bridge could not be built on subscribe
→ no media frame → browser showed streams but no audio / no level.

**Fix** — `meta-oe5xrx-remotestation/recipes-multimedia/oe5xrx-audio-system/oe5xrx-audio-system_1.0.bb`:
added to `RDEPENDS:${PN}`:

- `gstreamer1.0-plugins-good-rtp` → `rtpopuspay`, `rtpopusdepay`
- `gstreamer1.0-plugins-good-udp` → `udpsink`, `udpsrc`
- `gstreamer1.0-plugins-good-rtpmanager` → `rtpjitterbuffer`

**Why the specific split subpackages, not bare `gstreamer1.0-plugins-good`:** the bare
top package is EMPTY (`FILES:${PN}=""`) and only *RRECOMMENDS* `-meta` — a best-effort
dependency that can be dropped in an image build. This mirrors the existing precedent in
the same recipe, which pins `gstreamer1.0-plugins-base-opus` rather than bare `-base`.
Pinning the three sub-plugins also keeps the headless appliance image lean (no
v4l2/jpeg/png/... from the full `-good` set). Verified against
`openembedded-core/.../gstreamer1.0-plugins-packaging.inc` (per-plugin split
`libgst<name>.so → ${PN}-<name>`); `rtp`/`udp`/`rtpmanager` are core, dependency-free
plugins built unconditionally (no OFF-by-default PACKAGECONFIG gate, unlike `opus`).

**All live-bridge elements now resolve in the image:**
`rtpopuspay, rtpopusdepay, udpsink, udpsrc, rtpjitterbuffer, opusenc, opusdec,
pipewiresrc, pipewiresink` (+ `audioconvert`, `audioresample` from the already-pulled
`gstreamer1.0-plugins-base`).

## FIX#4 — CI coverage gap that let RC#1 through

The Session-E Tier-1 gate (`tests/ota-integration/test_audio_agent_e2e.py`) only exercised
the agent's `selftest audio` fdsink path, **not** the real live WS RTP bridge — so the
missing plugins passed CI green while live audio was dead.

**Gate extension (element-presence, the RC#1-catching minimum):**

- `tests/audio/agent_audio_selfcheck.sh` (E gate): new step "3c" asserts the FULL
  live-bridge element set via `gst-inspect-1.0` inside the captured OUTPUT block, before
  the selftest. On any missing element it emits `LIVE-BRIDGE-ELEMENTS result=FAIL
  missing:...`, dumps diag, and fails the gate loudly (`AGENT-AUDIO-E2E result=FAIL
  reason=missing_gst_element(...)`) — host state machine resolves cleanly, no hang.
- `tests/ota-integration/test_audio_agent_e2e.py`: host-side re-assertion of
  `LIVE-BRIDGE-ELEMENTS result=PASS` in the captured output, so the in-guest check can't
  be silently dropped (mirrors the existing FFT-ratio re-check).
- `tests/audio/audio_selfcheck.sh` (row-A gate, driven by `test_audio.py::test_a1`):
  extended its existing gst-element loop to the full live-bridge set — the canonical
  "elements present" gate now also fails loudly (`AUDIO-SELFTEST result=FAIL
  reason=no_<el>`) on a missing rtp/udp/rtpmanager element.

Result: a future image missing these plugins can no longer pass silently — it fails the
build (unresolvable RDEPENDS) or fails both audio gates with an explicit reason.

**Stretch (real bridge RX path in-guest) not taken:** element-presence already fully
catches THIS RC (RC#1 = elements absent from image; if all present, the bridge builds).
Running the real `build_rx_argv` UDP loopback under TCG adds harness complexity for
marginal additional coverage; noted as a possible future hardening.

## Pin coordination (IMPORTANT — orchestrator action before release)

The station-agent SRCREV pin in
`meta-oe5xrx-remotestation/recipes-core/station-agent/station-agent_0.1.0.bb` is left at
`2c80f96` — which is **exactly the current `station-manager` main** at the time of this
PR. gst-good makes the bridge runnable; RC#2 (parallel S1 session, control-plane) is
separate noise that does not block the media bridge.

**The final pin must be bumped to the post-RC#2 `station-manager`-main SHA before the
release — the orchestrator owns that bump (same as #85/#86). Do NOT auto-merge.**

## Verification

- `sh -n` clean on both gate scripts; `py_compile` + `ruff check` clean on the test.
- Recipe split-package names verified against OE gstreamer packaging; plugins are
  unconditionally built.
- Reviews: code-simplifier (no changes needed), audit/Watcher (split names correct, POSIX
  clean, gap closed), probe/QA (host↔guest flow traced, no false-green/hang path;
  flagged the audioconvert/audioresample omission, now fixed).
- Real CI (Yocto build + QEMU boot/OTA + extended audio gates) runs on the PR — see the
  GitHub Actions run linked from the PR.
