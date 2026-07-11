# Boot & OTA Integration Test — Design

**Date:** 2026-07-11
**Status:** Approved (brainstorming complete, pending implementation plan)
**Repos touched:** `linux-image` (test harness, dummy server, CI wiring, build-time guards). Consumes the `station-agent` binary already baked into the image; no `station-manager` code change.

## Problem

Two OTA-safety bugs shipped in published releases and only bit at runtime, on a real A/B OTA into the *other* slot. Neither was catchable by any existing check (recipe parse, shellcheck, yamllint, sim-harness):

1. **fs-label mismatch** (fixed in #36): the served rootfs carried label `root_a`; an OTA'd slot B was never relabelled to `root_b`, so x86 GRUB's `search --label root_b` failed and slot B was unbootable → rollback.
2. **ESP mounted by FAT UUID** (fixed in #37): the x86 `/boot` ESP was mounted via a build-time-regenerated FAT UUID. OTA rewrites only the rootfs, never the on-disk ESP, so an OTA'd slot's baked `UUID=` never matched the physical ESP → `/boot` timed out → systemd emergency mode → rollback. Diagnosed live via Proxmox VNC (`Timed out waiting for device /dev/disk/by-uuid/A5E9-662F`).

**Common shape:** both are runtime boot behaviours of a *cross-build* OTA'd slot. They appear ONLY when a **different** build's rootfs is written into slot B of an existing disk and that slot is actually **booted**. Static/unit tests cannot see them; the current CI never boots the image and never performs an OTA.

**Critical corollary — the cross-build requirement:** if a test used the *same* build for slot A and slot B, the ESP UUIDs would coincidentally match and bug #2 would hide. The test MUST use two different builds (last published release as slot A, the new build as slot B). This mirrors reality: the field station had `10-21` flashed and OTA'd `09-04`/`15`.

## Goals

- **Boot proof:** the freshly built image boots to multi-user (not emergency mode) and the agent reaches the network.
- **OTA proof:** a real cross-build A/B OTA cycle — last release → new build — boots the new slot and commits, driven through the agent's *real* OTA client code path.
- **Cheap first line:** a build-time static guard that fails the build on the exact bug-2 class (any device-`UUID=` mount in `/etc/fstab`).
- **Right gate:** never *publish* a release whose images don't boot + OTA.
- **Serial-first architecture** so a CM4 hardware target is a later transport drop-in, not a harness rewrite.

## Non-Goals (documented follow-ups)

- **CM4 / real-hardware HIL bench** — deferred; the serial-first transport abstraction keeps it a drop-in.
- **RPi-under-QEMU** (qemu raspi, TCG, slow) — deferred to a later nightly/bench.
- **Full `station-manager` E2E** (real server + agent) — the dummy server covers the agent's OTA contract; a real-server E2E is a heavier future layer.
- **Auth fidelity** — the dummy server does **not** verify the agent's Ed25519 signature (see Auth Fidelity). This is a boot/OTA test, not an auth test.
- **Nightly / every-PR full runs** — explicitly out (see Cadence).

## Success Criteria (per boot — an AND of two independent layers)

A boot counts as successful only if **both** hold:

1. **Serial layer:** the console shows the getty banner `OE5XRX Remote Station <expected-tag>` (from `/etc/issue`, stamped by `stamp_release`) **and then** the `login:` prompt. Emergency mode reaches neither — it drops to a `sulogin`/maintenance prompt — so this cleanly distinguishes bug-2's failure. The banner also carries the version, so it doubles as a version assertion.
2. **Application layer:** the agent checks in with the dummy server (heartbeat), and in the OTA test **commits** the deployment, reporting `new_version == <expected-tag>`.

The `<expected-tag>` is cross-checked at both layers (serial banner vs. agent-reported version) and against the fetched artifact's tag.

## Architecture

Three components, all in `linux-image` under `tests/ota-integration/` (mirrors the existing `tests/sim-harness/` convention).

### 1. Dummy OTA server

A minimal standalone HTTP server (Python stdlib `http.server` — zero third-party deps, matching the sim-harness spirit) that speaks exactly the endpoints the real agent uses (observed in production logs):

- `POST /api/v1/deployments/check/` → `{no update}` (T1) or `{update available: deployment N, image release <tag>}` (T2).
- `GET  /api/v1/deployments/<id>/download/` → streams the new build's rootfs artifact bytes.
- `POST /api/v1/deployments/<id>/status/` → records each status transition.
- `POST /api/v1/deployments/commit/` → records the commit (with reported version).
- heartbeat endpoint → records station check-ins (version, slot, health).

It **records** every agent interaction in-memory and exposes that record to the test (via an in-process handle or a `GET /_test/state` introspection route) so assertions read "did the agent commit with the new version?" rather than scraping logs. It is a **test double**, not a station-manager reimplementation.

**Contract-drift risk:** the dummy mirrors station-manager's agent protocol by hand; if that protocol changes, the dummy drifts silently. Mitigation: document the mirrored endpoints inline with a pointer to `station-manager` `apps/deployments/api_views.py`; a shared protocol schema is a future hardening.

### 2. Serial-driven test harness (pytest + pexpect)

A `Transport` abstraction decouples "how we reach the console/disk" from the test logic:

- **`QemuTransport` (now):** boots the wic with `qemu-system-x86_64` (OVMF/UEFI, the 4-partition A/B disk, `-serial` to a pexpect-readable pty/stdio, headless `-nographic`, QEMU user-net). Builds on the existing `scripts/run-qemu.sh` invocation. The agent reaches the host-side dummy server at `http://10.0.2.2:<port>` (QEMU's built-in host alias) — no bridge, no root networking.
- **`SerialDeviceTransport` (future):** `/dev/ttyUSB0` via pyserial for a CM4 bench. Same pexpect assertions.

The harness owns a **per-run copy** of the disk image (never mutates the cached artifact), pre-seeds config (below), boots, drives/asserts over serial, and queries the dummy server's recorded state.

### 3. Config injection — data-partition preseed (image stays unmodified)

We boot the **identical, signed production artifact**. Only the **data partition** carries test config — exactly how a real station is provisioned (`station-manager` writes there via guestfish). Before boot, the harness loop-mounts the disk's data partition (`losetup --find --partscan`, root available on the self-hosted runner) and writes into `etc-overlay/stationagent/` (the source of the `etc-stationagent.mount` overlay over `/etc/stationagent`):

- `config.yml` — `server_url: http://10.0.2.2:<port>`, `station_id: 1`, `ed25519_key_path: /etc/stationagent/device_key.pem`, `bootloader: grub`, and **tuned-down timers** (`heartbeat_interval: 10`, `ota_check_interval: 1`) so the OTA check + post-reboot commit happen in seconds, not the ~4 min seen in production.
- `device_key.pem` — a harness-generated Ed25519 private key (the dummy does not verify it).

**Open implementation detail (resolve in the plan):** confirm `data-init.service` / `data-init.sh` does not overwrite a pre-seeded `etc-overlay/stationagent/` on first boot. If it does, seed after the init settles or adjust the seed location. To be verified against `recipes-core/ab-layout/files/data-init.sh` when writing the plan.

## Test Flows

### T1 — boot smoke (single image)

1. Harness copies the **newly built** wic, pre-seeds test config on its data partition.
2. Dummy server up; `/check/` returns "no update".
3. Boot headless in QEMU.
4. **Assert (serial):** banner `OE5XRX Remote Station <new-tag>` → `login:`.
5. **Assert (dummy):** agent checked in (heartbeat) with `version == <new-tag>`.

Proves: image boots to multi-user + agent + network. (Does NOT catch bug #2 — a fresh flash has a matching ESP UUID. That's T2's job.)

### T2 — ★ cross-build OTA cycle (the money test)

1. Fetch the **last published release** wic (via `gh`, as `run-qemu.sh --release` already does) → disk = slot A + ESP with the *old* build's identifiers. Pre-seed test config on its data partition.
2. Dummy server configured to offer an update pointing at the **newly built** image's rootfs artifact.
3. Boot last-release in QEMU. Agent checks in → dummy offers update → agent runs its **real** OTA path: download (from dummy) → install to slot B → relabel `root_b` → set trial → reboot.
4. **Assert (serial):** after reboot the banner shows the **new** tag → `login:` (this is exactly where bug #2 manifested as emergency mode, and bug #1 as an unbootable slot → rollback to the old tag).
5. **Assert (dummy):** agent committed with `new_version == <new-tag>`.

A = old build, B = new build ⇒ genuinely cross-build ⇒ catches ESP-UUID **and** fs-label regressions. A code comment on the "fetch last release" step must state *why* it must differ from the build under test, so it's never "optimised" into a same-build shortcut that hides bug #2.

### T3 — rollback (follow-up, same harness)

Serve a deliberately broken slot-B rootfs (or force `bootcount > bootlimit`) → assert the bootloader reverts to slot A: banner shows the **old** tag and the agent reports `rolled_back`. Guards the safety net itself. Ships after T1/T2 are green.

## L0 — Build-time static guards (cheap, every PR)

Independent of QEMU, run on every PR (seconds, GH-hosted). A `ROOTFS_POSTPROCESS` assertion (and/or a CI grep over the built fstab where available) that **fails the build** when:

- `/etc/fstab` contains any device `UUID=` / `by-uuid` mount (only `PARTLABEL=`, `LABEL=`, or kernel-cmdline root are allowed). — would have caught bug #2 at build time, without ever booting.
- (nice-to-have) every non-`/` mount resolves via `PARTLABEL`.

Fast, deterministic, zero flake; complements — does not replace — the QEMU tests.

## Cadence & Triggers

Decided:

- **Every PR (GH-hosted, seconds):** existing `validate` (recipe parse, shellcheck, yamllint, wks/udev checks) **+ L0 static guards**.
- **Boot-critical PRs (path filter → self-hosted runner):** build image + **T1 + T2**. Path filter covers `meta-oe5xrx-remotestation/wic/**`, `recipes-bsp/**` (grub-ab, u-boot-ab), `recipes-core/ab-layout/**`, `recipes-core/images/**`, and the `station-agent` SRCREV pin. Shift-left: a boot/OTA regression fails in the PR, not at release.
- **Release (tag push) — the gate:** restructure `release.yml` so it builds → **T1 + T2** → **publishes only if green**. The backstop that would have stopped both shipped bugs before any station saw them.

Explicitly **out**: nightly scheduled runs and every-PR full runs (path-filter + release-gate cover the boot-critical surface; the ~10–20 min TCG cost isn't worth paying on every PR or nightly for a repo with no external drift sources).

## Runner & Performance (no KVM → TCG)

The self-hosted runner has no `/dev/kvm`, so QEMU runs under **TCG** (pure emulation). A single x86 boot is ~1–3 min; T2 (two boots + download/install) is ~10–20 min wall-clock. Acceptable given the trigger set (boot-critical PRs + release, both infrequent). The harness must use generous, condition-based serial timeouts (pexpect `expect` on the banner/login/commit, not fixed sleeps) so TCG slowness never flakes the test. RPi-under-QEMU (even slower under TCG) stays deferred.

## Auth Fidelity

The agent signs requests with an Ed25519 key (`station_id` + `ed25519_key_path`). The dummy server **does not verify** the signature — it is a test double focused on boot/OTA behaviour. The harness still provides a valid `device_key.pem` and `station_id` so the agent's config validates and it *sends* signed requests; the server just doesn't check them. Signature verification is a documented future hardening if we ever want the dummy to double as an auth test.

## Risks & Open Items

- **`data-init` overwrite** of the pre-seeded config — verify against `data-init.sh` in the plan (see Config Injection).
- **Protocol drift** dummy ↔ station-manager — documented endpoint mirroring now; shared schema later.
- **TCG flake** — condition-based waits with generous timeouts, never fixed sleeps.
- **Disk mutation** — always operate on a per-run copy of the fetched/built wic.
- **Artifact availability** — T2 needs both the new build (from the Build job) and the last release (`gh release`); the release-gate run has both by construction, the PR run fetches the last release.

## Verification of the Test Itself

Before declaring the harness trustworthy, prove it *fails* on the very bugs it targets:

- Temporarily revert #37 (re-introduce the ESP `--use-uuid`) → **T2 must go red** (emergency mode / rollback), L0 must go red at build time.
- Temporarily revert #36 (skip the relabel) → **T2 must go red** (slot B unbootable → rollback).
- Both reverted back out; tests green. A test that can't catch the known bug is worthless.

## Future Work

- **CM4 HIL bench** via `SerialDeviceTransport` — the unified serial/UART strategy from the project README.
- **RPi-under-QEMU** target in the same harness (nightly, once x86 is stable).
- **Full `station-manager` E2E** — real server + agent, to also cover server↔agent protocol and the deployment state machine.
- **Shared agent-protocol schema** so the dummy server can't drift from the real server.
