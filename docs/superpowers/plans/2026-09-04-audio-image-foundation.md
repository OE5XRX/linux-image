# Session A — Audio Image Foundation (linux-image)

**Date:** 2026-09-04
**Spec 0:** `station-manager/docs/superpowers/specs/2026-09-03-audio-subsystem-design.md`
(§3/§4 device-mapping, §8 sim substrate, §9 row A, §10 open decisions)
**Scope:** Image-foundation + sim substrate ONLY. No agent pipeline (B), no server (C),
no web (D).

---

## Deliverables

1. **Multimedia layer + deps in the image.** Enable `meta-multimedia` in Kas; add
   PipeWire 1.6.8, WirePlumber 0.5.14, GStreamer 1.28.2 (+ `opus` and `pipewire`
   plugins), `libopus` 1.6.1 to the image.
2. **System-wide audio services.** PipeWire + WirePlumber as **systemd system
   services** (headless appliance, not per-user), running as the recipe-provided
   `pipewire` system user/group, socket at `/run/pipewire/pipewire-0`.
3. **udev `slotN/audio` mapping.** `SUBSYSTEM=="sound"` rules that tag the module's
   sound device with `ENV{OE5XRX_SLOT}=N`; WirePlumber renames the node to
   `oe5xrx.slotN`.
4. **Sim-harness audio extension (§8).** Load `snd-aloop`, present it as slot1 audio
   (same `oe5xrx.slot1` node as real HW), and drive a self-contained 1 kHz tone into
   the loopback playback side so the capture side (RX tap) yields a known tone.
5. **Kernel fragment.** `CONFIG_SND_ALOOP=m` (+ base ALSA) for qemux86-64.
6. **Tests + CI.** Extend `tests/sim-harness/` and `ci.yml`; QEMU-boot FFT proof.

---

## §10 Decisions (made + rationale)

### D1 — Tone-shim home: **self-contained in the linux-image sim-harness**
Not a co-versioned FW-RemoteStation release asset. A pure 1 kHz sine has **zero
firmware coupling** — unlike `sa818-sim.py`, which emulates real SA818 AT-protocol
semantics that must co-version with the `native_sim` binary. A tone generator is
generic; pinning it to an FW release would add release-bump churn for no
shared-truth benefit. Implemented with GStreamer already in the image:
`gst-launch-1.0 audiotestsrc is-live=true wave=sine freq=1000 ! audioconvert !
audioresample ! alsasink device=hw:<aloop>,0,0`.

### D2 — `slotN/audio` udev mechanism: **ENV tag + WirePlumber rename → `oe5xrx.slotN`**
ALSA devices cannot carry stable `/dev` symlinks the way `tty` does (the agent
consumes **PipeWire nodes**, not `/dev/snd/*` paths). So, mirroring the tty rule:
- udev matches the sound device by **USB hub port path** (`SUBSYSTEM=="sound"`,
  `KERNELS=="1-1.N"`) on real HW and sets `ENV{OE5XRX_SLOT}="N"`,
  `ENV{OE5XRX_SLOT_ROLE}="audio"`.
- In **sim**, the `snd-aloop` card is loaded with a stable id (`modprobe snd-aloop
  id=oe5xrxslot1 ...`) and a `SUBSYSTEM=="sound", ATTRS{id}=="oe5xrxslot1"` rule
  sets the **same** `ENV{OE5XRX_SLOT}="1"`.
- **WirePlumber** (`monitor.alsa.rules`) matches the card and rewrites
  `node.name` → **`oe5xrx.slotN`** (nick/description too). The match predicate that
  is proven in sim is the aloop card id; the real-HW predicate (USB port path) is
  co-designed and bench-verified later — exactly like the tty rule, whose real half
  is also only bench-verified.

**Interface / naming convention (firm, for Session B):**
- PipeWire node per slot = **`oe5xrx.slotN`**.
  - capture side  = RX **source**  → agent stream `slotN.rx`
  - playback side = TX **sink**    → agent stream `slotN.tx`
- The agent resolves `slot N → node "oe5xrx.slotN"`; **identical in sim and real**.

### D3 — PipeWire system-mode: **dedicated system units, `pipewire` user, `/run/pipewire`**
Rather than rely on the ambiguous upstream user/system unit semantics, ship explicit
`oe5xrx-pipewire.service` + `oe5xrx-wireplumber.service` system units that launch
`/usr/bin/pipewire` and `/usr/bin/wireplumber` as `User=pipewire Group=pipewire`
with `RuntimeDirectory=pipewire` and `PIPEWIRE_RUNTIME_DIR=/run/pipewire`. Drop-in
conf marks the daemon system-wide, sets the socket `pipewire-0` group-`pipewire`
0660, and disables session/D-Bus/login features absent on a headless box.

**Interface / socket contract (firm, for Session B):**
- Socket = **`/run/pipewire/pipewire-0`**.
- Required group = **`pipewire`**. The `station_agent` service (Session B) must run
  with supplementary group `pipewire` and `PIPEWIRE_RUNTIME_DIR=/run/pipewire`.

---

## Okay-Gate (Spec 0 §7 row A + §8)
- Image builds for qemux86-64 (mandatory) and rpi64 (recipe parse / build-start).
- QEMU x64 boot asserts:
  - `systemctl is-active oe5xrx-pipewire oe5xrx-wireplumber` = active
  - `gst-inspect-1.0 opusenc` and `gst-inspect-1.0 pipewiresrc` present
  - `wpctl status` lists node `oe5xrx.slot1`
  - record ~1 s off `oe5xrx.slot1` capture → FFT shows a 1 kHz peak
- `tests/sim-harness/` + CI extended with the audio checks.
</content>
