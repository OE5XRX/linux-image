# Spec 3 — Shared-Cache Hardening (Focus Trio)

**Status:** design approved, ready for implementation plan
**Depends on:** Spec 1 (shared sstate/downloads mirror) + Spec 2 (ydev local+remote loop) — both merged to `main`.

## Goal

Keep the shared-cache infrastructure **deterministic, fast, and self-maintaining** over time. Spec 1+2 deliver the value (warm builds, dev loop); Spec 3 stops it from rotting: the Storage Box filling up, source drift causing cache misses, and giant git fetches over sshfs.

Three coordinated components. A shared `bitbake-hashserv` (higher cross-machine reuse) is explicitly **deferred to a future Spec 4** — with a lockfile pinning commits (C1), hashes already match across machines, so hashserv's marginal benefit is small relative to its always-on ops cost.

## Motivating incidents (from live testing)

- A local kernel `do_fetch` ran a full `git clone --bare --mirror` of `linux-yocto` (**3.7 GB**) written **over sshfs** to the Storage Box → **85+ minutes**, effectively unusable. (→ C2)
- Builds re-fetched/rebuilt the kernel because the layers float on branches (`wrynose`, `2.18`) and `linux-yocto` resolved a newer commit than a prior build → sstate miss + the "Using branch without commit … unsafe. Either add a commit or use a lock file" warnings. (→ C1)
- The shared `sstate`/`downloads` on the box only ever grow (push is `rsync --ignore-existing`, nothing prunes) → the box will fill. (→ C3)

## Scope

In scope: **C1** deterministic+current sources (kas lockfile + kernel pin cleanup + auto bump-bot), **C2** shallow git fetch, **C3** scheduled cache pruning.

Out of scope (deferred): shared `bitbake-hashserv` (Spec 4); moving `DL_DIR` local / premirror (not needed once C2 makes fetches tiny).

---

## C1 — Deterministic & current sources

### Kernel pin cleanup
Today's kernel version handling mixes a legitimate parity lever with a bogus debug freeze:

- `oe5xrx.yml` `local_conf_header`: `PREFERRED_VERSION_linux-yocto = "6.18.%"` and `PREFERRED_VERSION_linux-raspberrypi = "6.18.%"`.
- `meta-oe5xrx-remotestation/dynamic-layers/raspberrypi/recipes-kernel/linux/linux-raspberrypi_6.18.bbappend`: `LINUX_VERSION = "6.18.39"` + `SRCREV_machine = "60ea684a…"`.

Decisions:

- **Remove the hard RPi freeze** (`LINUX_VERSION` + `SRCREV_machine`, i.e. the `linux-raspberrypi_6.18.bbappend` pin). It was set chasing a suspected CM4 USB bug that turned out to be something else — **not load-bearing**. A hard `SRCREV` never served qemu↔RPi parity anyway (the two kernels are different forks with unrelated SRCREVs; see below).
- **Keep the version-LINE preference** `PREFERRED_VERSION_*_ = "6.18.%"` on **both** providers. This is what gives **version parity** between qemu and RPi (both track the newest `6.18.x`) and "newest within the line".
- **Keep `station-agent` `SRCREV` pinned** — this is OE5XRX's own component, deliberately pinned per the project rule ("station-agent is never built with AUTOREV; SRCREV as a lockfile"). Not an upstream version to float.
- **Keep the version-agnostic `%.bbappend` fragments** (`oe5xrx-watchdog.cfg`, `oe5xrx-ikconfig.cfg`) for both `linux-yocto` and `linux-raspberrypi`.

**qemu ↔ RPi kernel reality (rationale):** qemux86-64 uses the `linux-yocto` provider; raspberrypi4-64 uses the `linux-raspberrypi` provider (the RPi Foundation fork with BSP patches). They can share a *version line* (6.18.x) but never the same source/SRCREV. So parity = same version line, achieved by the `PREFERRED_VERSION` wildcard on both, **not** by a hard SRCREV pin. Moving to a newer line (e.g. 6.18 → 6.x) is a deliberate, tested decision and is only possible when **both** layers provide that line.

### kas lockfile
- Generate `oe5xrx.lock.yml` via `kas dump --lock --update --inplace oe5xrx.yml`, commit it. kas auto-loads the sibling `.lock.yml` → local/remote/CI resolve **identical layer commits** → deterministic recipes (including the kernel SRCREV, transitively via the pinned `meta-yocto` / `meta-raspberrypi`). Eliminates the drift cache-misses and the "unsafe branch" warnings.
- The lockfile pins the *commit*; the `PREFERRED_VERSION` wildcard selects the *line*; together: reproducible exact point-release per lock, parity across arches.

### Bump bot
- A scheduled workflow (`.github/workflows/lockfile-bump.yml`, e.g. weekly) runs `kas dump --lock --update` and, when the lock changes, opens a **PR** with the diff (e.g. `peter-evans/create-pull-request` or `gh pr create`). Reviewed/merged like a dependency bump → tracks newest-stable, controlled, cache-friendly (no silent per-build drift).

### Validation (main risk area)
Un-pinning the exact commit **changes which kernel gets built**. C1 therefore **requires a real build** to confirm:
- a valid newest `6.18.x` is selected for **both** `linux-yocto` (x86) and `linux-raspberrypi` (RPi);
- images build and boot (x86 via warm cache + QEMU; an RPi build at minimum, ideally boot);
- the watchdog + ikconfig kconfig fragments still apply.

Nuance to resolve in-build: removing `PREFERRED_VERSION` *entirely* yields the distro default (often an older LTS), which is **not** "newest". Keeping the `6.18.%` wildcard (or bumping it to the newest line both layers offer) is how we get newest-within-line. The build confirms the resulting versions.

---

## C2 — Shallow git fetch

- Add `BB_GIT_SHALLOW = "1"` to the `oe5xrx.yml` `local_conf_header`. Only the pinned commit is fetched (GB → MB), so the fetch over the shared sshfs `DL_DIR` is tiny/fast. Works cleanly **because** the lockfile pins SRCREVs (shallow needs a fixed revision). `DL_DIR` stays shared → one small shallow tarball per pinned commit, reused across machines.
- **Depends on C1** (lockfile) landing first for determinism.
- Clean up the **aborted 3.7 GB partial `linux-yocto` clone** left in the mirror (no `.done` marker) so the next fetch starts clean — one-time, and/or handled by C3's leftover cleanup.
- Validate: a clean kernel fetch is small and fast; a full build still succeeds with shallow enabled (watch for recipes with `AUTOREV` that dislike shallow — with the lockfile pinning, none should).

---

## C3 — Scheduled cache pruning

A scheduled workflow (`.github/workflows/cache-prune.yml`, e.g. nightly/weekly) mounts the Storage Box (reusing `build.yml`'s bws-fetch + sshfs steps) and prunes:

- **sstate:** `openembedded-core/scripts/sstate-cache-management.py --cache-dir=/mnt/yocto-shared/sstate --remove-duplicated --yes` — keeps the newest per object, removes only older duplicates. The in-use current sstate is never touched.
- **downloads:** prune **only stale/unreferenced** entries — by age (e.g. not accessed in > 45 days) and/or not referenced by the current (locked) sources. The currently-pinned kernel/agent sources are **never** removed. (Safety net: downloads are idempotently re-fetchable, so a mistaken deletion is at worst a re-download — and with C2 that re-download is small.)
- **leftovers:** remove partial clones / stale `.lock` files (incl. today's aborted `linux-yocto` clone).

Design points:
- **Dry-run first** (the script supports listing) — verify it keeps current sstate and only removes old duplicates before enabling deletion.
- Retention thresholds exposed as workflow inputs (`workflow_dispatch`) with conservative defaults.
- **Concurrency:** schedule at a low-activity time; `--remove-duplicated` does not touch in-use current objects, so a concurrent build is safe — documented as an accepted, bounded risk (matches Spec 1's accepted DL_DIR shared-write note).

---

## Cross-cutting

- **Docs:** update `docs/dev-shared-cache.md` — the lockfile bump flow, `BB_GIT_SHALLOW` behavior, the prune schedule + retention.
- **CI green:** `yamllint` (two new workflow files) + `shellcheck` (any new scripts). Commit subjects imperative ≤72 chars; end with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`; squash-merge; **one PR** (spec + plan + code on this branch).

## Implementation order (for the plan)

1. **C1** — pin cleanup + generate/commit lockfile + **build-validate** the resulting kernel versions (x86 + RPi). *(Riskiest; do first — everything else assumes deterministic sources.)*
2. **C2** — `BB_GIT_SHALLOW` + mirror leftover cleanup; validate a small fast fetch + full build.
3. **C1 bump-bot** workflow.
4. **C3** — prune workflow (dry-run → enable).

## Open / to-resolve during implementation

- Exact `PREFERRED_VERSION` form for "newest within line" vs distro default — decided by the C1 build (which versions actually result for both providers).
- Whether the aborted partial clone is cleaned by a one-off step or folded into C3.
- Bump-bot PR mechanism (action vs `gh`) and cadence.
- Prune retention thresholds (defaults + inputs).
