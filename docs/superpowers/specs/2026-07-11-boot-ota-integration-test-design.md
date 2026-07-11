# Boot & OTA Integration Test — Design

**Date:** 2026-07-11
**Status:** Approved (brainstorming complete, pending implementation plan)
**Repos touched:** `linux-image` (test harness, dummy server, CI wiring, build-time guards, release-workflow rework). Consumes the `station-agent` binary already baked into the image. One small **follow-up in `station-manager`**: a contract test pinning the agent-protocol shapes the dummy mirrors (no code dependency, just drift protection).

## Problem

Two OTA-safety bugs shipped in published releases and only bit at runtime, on a real A/B OTA into the *other* slot. Neither was catchable by any existing check (recipe parse, shellcheck, yamllint, sim-harness):

1. **fs-label mismatch** (fixed in #36): the served rootfs carried label `root_a`; an OTA'd slot B was never relabelled to `root_b`, so x86 GRUB's `search --label root_b` failed and slot B was unbootable → rollback.
2. **ESP mounted by FAT UUID** (fixed in #37): the x86 `/boot` ESP was mounted via a build-time-regenerated FAT UUID. OTA rewrites only the rootfs, never the on-disk ESP, so an OTA'd slot's baked `UUID=` never matched the physical ESP → `/boot` timed out → systemd emergency mode → rollback. Diagnosed live via Proxmox VNC (`Timed out waiting for device /dev/disk/by-uuid/A5E9-662F`).

**Common shape:** both are runtime boot behaviours of a *cross-build* OTA'd slot. They appear ONLY when a **different** build's rootfs is written into slot B of an existing disk and that slot is actually **booted**. Static/unit tests cannot see them; the current CI never boots the image and never performs an OTA.

**Critical corollary — the cross-build requirement:** if a test used the *same* build for slot A and slot B, the ESP UUIDs would coincidentally match and bug #2 would hide. The test MUST use two different builds (last published release as slot A, the new build as slot B). This mirrors reality: the field station had `10-21` flashed and OTA'd `09-04`/`15`.

## Goals

- **Boot proof:** the freshly built image boots to multi-user (not emergency mode) and the agent reaches the network.
- **OTA proof:** a real cross-build A/B OTA cycle — last release → new build — boots the new slot and commits, driven through the agent's *real* OTA client code path.
- **Cheap first line:** a static lint on every PR + an authoritative build-time guard, both targeting the bug-2 class (any device-`UUID=` mount).
- **Right gate:** never *publish* a release whose x86 image doesn't boot + OTA.
- **One-button release:** the release becomes a manually-dispatched workflow that computes its own next version (mirrors the FW-RemoteStation pattern) — no more tag-push trigger.
- **Reusable workflows + swappable runner:** build, boot-ota-test, and version-compute are reusable; the test runner is a parameter so GH-hosted ↔ Hetzner is a one-line flip.
- **Serial-first architecture** so a CM4 hardware target is a later transport drop-in, not a harness rewrite.

## Non-Goals (documented follow-ups)

- **CM4 / real-hardware HIL bench** — deferred; the serial-first transport abstraction keeps it a drop-in.
- **RPi-under-QEMU** (qemu raspi, TCG, slow) — deferred. The release gate therefore tests **x86 only**; a broken RPi image could still publish (known gap).
- **Full `station-manager` E2E** (real server + agent) — the dummy server covers the agent's OTA contract faithfully (see Dummy Server); a real-server E2E is a heavier, separate future layer.
- **Auth verification** — the dummy does **not** verify the agent's Ed25519 request signature (test double). See Auth & Payload Fidelity.
- **Nightly / every-PR full runs** — out. Path-filtered PRs + the release gate cover the boot-critical surface.
- **KVM acceleration** — unavailable on both GH-hosted and Hetzner Cloud (no nested virt); everything runs under TCG. True KVM would need bare-metal, out of scope.

## Success Criteria (per boot — an AND of two independent layers)

A boot counts as successful only if **both** hold:

1. **Serial layer:** the console shows the getty banner `OE5XRX Remote Station <expected-tag>` (from `/etc/issue`, stamped by `stamp_release`) **and then** the `login:` prompt. Emergency mode reaches neither — it drops to a `sulogin`/maintenance prompt — so this cleanly distinguishes bug-2's failure. The banner carries the version, doubling as a version assertion.
2. **Application layer:** the agent checks in with the dummy server (heartbeat), and in the OTA test **commits** the deployment, reporting `new_version == <expected-tag>`.

`<expected-tag>` is cross-checked at both layers and against the fetched artifact's tag.

## Architecture

Three components in `linux-image` under `tests/ota-integration/` (mirrors the existing `tests/sim-harness/`).

### 1. Dummy OTA server (standalone, no station-manager dependency)

A minimal stdlib `http.server` speaking exactly the agent's endpoints (observed in production logs):

- `POST /api/v1/deployments/check/` → `{no update}` (T1) or `{update available: deployment N, image release <tag>, download_url, sha256}` (T2).
- `GET  /api/v1/deployments/<id>/download/` → streams the new build's **bz2-compressed rootfs** bytes.
- `POST /api/v1/deployments/<id>/status/` → records each status transition.
- `POST /api/v1/deployments/commit/` → records the commit (with reported version).
- heartbeat endpoint → records station check-ins (version, slot, health).

It **records** every agent interaction and exposes it to the test (in-process handle or `GET /_test/state`) so assertions read "did the agent commit with the new version?" rather than scraping logs.

**Why a standalone dummy, not reused station-manager code — settled by a code fact:** the agent verifies only a **SHA-256** checksum on the OTA download (`ota.py:download_firmware` stream-decompresses the bz2 rootfs into the slot), **not** a cosign signature; and it **signs** its requests with Ed25519 (`signing.py`) which a test double need not verify. So the dummy only has to serve the real `rootfs.bz2` + its `sha256` and accept signed requests — and the agent then runs its **complete real OTA code path** (check → download → sha256 → decompress → install → relabel → trial → reboot → commit). Reusing station-manager server code would add only wire-protocol/auth fidelity, which (a) is station-manager's own test turf — the agent *lives* in that repo and versions with the server — and (b) is not turnkey (no compose stack; would need Postgres+Redis+Django assembled in CI). Not worth the heavy cross-repo dependency for an *image* test.

**Drift guard (cheap, in place of the dependency):** document the mirrored endpoints inline with a pointer to `station-manager` `apps/deployments/api_views.py`, plus a small **contract test in station-manager** asserting the response shapes the dummy relies on. Makes drift visible without coupling build/test envs.

### 2. Serial-driven test harness (pytest + pexpect)

A `Transport` abstraction decouples "how we reach the console/disk" from the test logic:

- **`QemuTransport` (now):** boots the wic with `qemu-system-x86_64` (OVMF/UEFI, the 4-partition A/B disk, `-serial` to a pexpect pty, headless `-nographic`, QEMU user-net). Builds on `scripts/run-qemu.sh`. The agent reaches the host-side dummy server at `http://10.0.2.2:<port>` (QEMU's host alias) — no bridge, no root networking.
- **`SerialDeviceTransport` (future):** `/dev/ttyUSB0` via pyserial for a CM4 bench. Same pexpect assertions.

The harness owns a **per-run copy** of the disk image (never mutates the cached artifact), pre-seeds config, boots, drives/asserts over serial, and queries the dummy's recorded state. **Condition-based waits only** (pexpect `expect` on banner/login/commit, never fixed sleeps) so TCG slowness never flakes.

### 3. Config injection — data-partition preseed (image stays unmodified)

We boot the **identical, signed production artifact**. Only the **data partition** carries test config — exactly how a real station is provisioned. Before boot, the harness loop-mounts the disk's data partition (`losetup --find --partscan`, root available on the runner) and writes into `etc-overlay/stationagent/` (the source of the `etc-stationagent.mount` overlay over `/etc/stationagent`):

- `config.yml` — `server_url: http://10.0.2.2:<port>`, `station_id: 1`, `ed25519_key_path: /etc/stationagent/device_key.pem`, `bootloader: grub`, and **tuned-down timers** (`heartbeat_interval: 10`, `ota_check_interval: 1`) so the OTA check + post-reboot commit happen in seconds, not the ~4 min seen in production.
- `device_key.pem` — a harness-generated Ed25519 private key (the dummy does not verify it).

**Open (resolve in the plan):** confirm `data-init.service` / `data-init.sh` does not overwrite a pre-seeded `etc-overlay/stationagent/` on first boot.

## Auth & Payload Fidelity

- **Requests:** the agent signs with Ed25519 (`station_id` + `ed25519_key_path`). The dummy accepts signed requests but does **not** verify them (test double). The harness still provides a valid key + `station_id` so the agent's config validates and it sends real signed requests. Signature verification is a future hardening if the dummy should double as an auth test.
- **Payload:** the OTA download is a **bz2-compressed rootfs**, verified by the agent against a **SHA-256** it gets from the deployment/check response — no cosign on the agent side. The dummy serves the real `rootfs.bz2` from the build artifact and the matching `sha256`. (Plan-time: ensure the build artifact includes the rootfs `.bz2` the server would serve, and compute its sha256 for the dummy.)

## Test Flows

### T1 — boot smoke (single image)
1. Copy the **newly built** wic, pre-seed test config on its data partition.
2. Dummy up; `/check/` returns "no update".
3. Boot headless.
4. **Assert (serial):** banner `OE5XRX Remote Station <new-tag>` → `login:`.
5. **Assert (dummy):** agent checked in with `version == <new-tag>`.

Proves boot-to-multi-user + agent + network. Does NOT catch bug #2 (fresh flash → matching UUID). That's T2.

### T2 — ★ cross-build OTA cycle (the money test)
1. Fetch the **last published release** wic (via `gh`, as `run-qemu.sh --release`) → disk = slot A + ESP with the *old* build's identifiers. Pre-seed test config.
2. Dummy offers an update pointing at the **newly built** rootfs.bz2 (+ sha256).
3. Boot last-release. Agent checks in → dummy offers update → agent runs its **real** OTA path (download → sha256 → decompress → install slot B → relabel `root_b` → trial → reboot).
4. **Assert (serial):** after reboot, banner shows the **new** tag → `login:` (exactly where bug #2 = emergency mode and bug #1 = unbootable-B → rollback-to-old-tag manifested).
5. **Assert (dummy):** agent committed with `new_version == <new-tag>`.

A=old build, B=new build ⇒ genuinely cross-build ⇒ catches ESP-UUID **and** fs-label. A code comment on the "fetch last release" step must state *why* it must differ from the build under test, so it's never "optimised" into a same-build shortcut that hides bug #2.

### T3 — rollback (follow-up, same harness)
Serve a deliberately broken slot-B rootfs (or force `bootcount > bootlimit`) → assert revert to slot A: banner shows the **old** tag, agent reports `rolled_back`. Ships after T1/T2 are green.

## L0 — Build-time / static guards (cheap)

Two layers, because the fstab only exists after a build:

- **L0a — static lint, every PR (GH-hosted, seconds):** grep the wks/recipes for the *dangerous pattern* — a mountpointed `part … --use-uuid` **without** `--no-fstab-update`, or a recipe writing `UUID=` into fstab. Would have caught bug #2 at the source (the wks had exactly that). Heuristic early-warning; runs without a build.
- **L0b — `ROOTFS_POSTPROCESS` assertion, during the build (authoritative):** fails the build on *any* device-`UUID=` mount in the real fstab (also catches wic auto-injection). Runs whenever a build runs (boot-critical PRs + release).

## Pipeline

Runner is a **parameter** on `boot-ota-test.yml` (`runs-on` / `runner_label`) — default GH-hosted `ubuntu-latest`, flip to the Hetzner runner in one line if the feasibility spike (below) says GH is insufficient.

Reusable pieces: `build.yml` (`workflow_call`, existing), **`boot-ota-test.yml`** (`workflow_call`, new — downloads the new x64 artifact from the same run, fetches slot-A release, installs qemu+ovmf, runs pytest T1+T2), and a **`compute-version`** composite action.

```
① ci.yml            on: pull_request, push→main        (GH-hosted, seconds)
   validate ─┬─ recipe-parse / shellcheck / yamllint / wks / udev
             └─ L0a  (static UUID-pattern lint)                 [NEW]

② boot-ota-pr.yml   on: pull_request, paths:            (boot-critical only)
      [ wic/** · recipes-bsp/** (grub/u-boot) · ab-layout/** · images/** · station-agent SRCREV pin ]
   build-x64 (uses build.yml, machine=qemux86-64, dev stamp)    ← L0b runs inside the build
        └─► boot-ota-test (uses boot-ota-test.yml)   ← T1+T2, fails the PR check on red

③ release.yml       on: workflow_dispatch              (ONE-BUTTON + GATE)   [REWORKED]
   compute-version ─ next YYYY.MM.DD-HH (suffix [a-z] bump on collision; reads existing releases)
   → preflight (SRCREV / FM-artifact pins)
   → [ build-x64 , build-rpi ]              (L0b runs in both)
        └─► boot-ota-test (uses boot-ota-test.yml, x64)          [NEW gate step]
   → publish (softprops/action-gh-release creates the tag)   needs:[build-x64, build-rpi, boot-ota-test]
                                                             ← publishes ONLY if the test is green
```

**Release trigger change:** drop the `on: push: tags` trigger; release is now `workflow_dispatch` (inputs: `dry_run`, optional `version` override). `compute-version` computes the next hour-stamp itself (mirrors `FW-RemoteStation/.github/workflows/release.yml`), and `action-gh-release` creates the tag at publish time. The existing `YYYY.MM.DD-HH[a-z]` scheme is kept (regex, `run-qemu.sh`, all existing tags depend on it) — only the computation moves into the workflow. `scripts/release.sh` becomes a thin `gh workflow run` wrapper or is retired.

At the gate the new tag isn't published yet, so `gh release list` → latest = the **previous** release = slot A. Slot B = the just-built artifact ⇒ cross-build for free.

## Runner Feasibility (no KVM → TCG)

Both GH-hosted and Hetzner Cloud lack nested virt, so QEMU runs under **TCG** either way — the Hetzner fallback is only *faster/more cores* (CCX43 = 8 dedicated vCPU) vs GH-hosted's 4 shared vCPU, not KVM acceleration.

**Feasibility spike = the first implementation step.** Before building the full harness, boot the current published release under TCG on `ubuntu-latest` and measure: boot-to-`login:` time, guest+host RAM, and especially **disk** (GH-hosted = 4 vCPU / 16 GB RAM / **14 GB disk** — the fetched last-release wic + new rootfs + per-run working copies are the tightest constraint). Decision gate:

- Boots reliably in acceptable wall-clock and fits disk → **GH-hosted** (free, simple).
- Too slow / OOM / disk-tight → **Hetzner**, preferably by reusing the **ephemeral build server** (build → test-on-same-box → delete; artifact already local, beefier TCG). Flip via the `runs-on` parameter.

## Risks & Open Items

- **GH-hosted sufficiency** — resolved by the feasibility spike (above), not assumed.
- **`data-init` overwrite** of the pre-seeded config — verify against `data-init.sh` in the plan.
- **Protocol drift** dummy ↔ station-manager — documented endpoint mirroring + a station-manager contract test.
- **TCG flake** — condition-based waits, generous timeouts, never fixed sleeps.
- **Disk mutation** — always operate on a per-run copy of the fetched/built wic.
- **RPi gate gap** — the release gate tests x86 only; a broken RPi image can still publish. Documented; closable later.
- **Build artifact must include the rootfs `.bz2`** the OTA serves (+ sha256) — confirm in the plan.

## Verification of the Test Itself

Before trusting the harness, prove it *fails* on the very bugs it targets:

- Temporarily revert #37 (re-introduce the ESP `--use-uuid`) → **T2 red** (emergency/rollback), **L0b red** at build time, **L0a red** at lint time.
- Temporarily revert #36 (skip the relabel) → **T2 red** (slot B unbootable → rollback).
- Revert both back out; tests green. A test that can't catch the known bug is worthless.

## Future Work

- **CM4 HIL bench** via `SerialDeviceTransport` — the unified serial/UART strategy.
- **RPi-under-QEMU** target + gate (nightly, once x86 is stable).
- **Full `station-manager` E2E** — real server + agent, to also cover server↔agent protocol and the deployment state machine.
- **Ed25519 verification** in the dummy, if it should double as an auth test.
