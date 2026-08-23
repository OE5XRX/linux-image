# Spec 3 — Shared-Cache Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the shared Yocto cache deterministic (kas lockfile + kept version-line pins), fast (shallow git fetch), and self-maintaining (scheduled pruning + auto lockfile-bump PR).

**Architecture:** Config changes in `oe5xrx.yml` + a deleted kernel pin (C1/C2), a committed `oe5xrx.lock.yml` (C1), and two new GitHub Actions workflows — a lockfile bump-bot and a cache-prune job that mounts the Storage Box like `build.yml` (C1/C3). Full x86+RPi builds validate C1/C2 and are run manually/in CI (a human gate), not by subagents.

**Tech Stack:** kas (in `~/OE5XRX/.kas-venv`), BitBake/OE (`wrynose`), GitHub Actions, bash, sshfs, `openembedded-core/scripts/sstate-cache-management.py`, yamllint, shellcheck.

**Spec:** `docs/superpowers/specs/2026-08-24-spec3-shared-cache-hardening-design.md`

## Global Constraints

- **kas is NOT on PATH locally** — every local kas command runs via the venv: `source ~/OE5XRX/.kas-venv/bin/activate` first (or call `~/OE5XRX/.kas-venv/bin/kas`). CI has its own kas.
- **Keep these deliberate pins/fragments** (do NOT touch): `PREFERRED_VERSION_linux-yocto = "6.18.%"` and `PREFERRED_VERSION_linux-raspberrypi = "6.18.%"` in `oe5xrx.yml` (qemu↔RPi version parity); the `station-agent` `SRCREV` pin; the version-agnostic `meta-oe5xrx-remotestation/recipes-kernel/linux/linux-yocto_%.bbappend` and `linux-raspberrypi_%.bbappend` fragments (watchdog + ikconfig).
- **`oe5xrx.lock.yml` must be tracked** (it is not gitignored) so local/remote/CI all use it.
- **`BB_GIT_SHALLOW` depends on the lockfile** (needs fixed SRCREVs) → C1 lockfile lands before C2 shallow.
- **Full builds (x86 + RPi) and prune runs are manual/CI**, not local — the plan marks those steps `[HUMAN]`. Local validation for config = `kas dump <machine>.yml` parses; for workflows/scripts = `yamllint` + `shellcheck`.
- **CI green:** `yamllint` (new workflow YAML) + `shellcheck` (new scripts). Commit subjects imperative ≤72 chars; end every commit with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Squash-merge. **One PR** (spec + plan + code on `feat/spec3-shared-cache-hardening`).

---

### Task 1: Remove the phantom RPi kernel pin

The `linux-raspberrypi_6.18.bbappend` freezes the RPi kernel to 6.18.39 chasing a supposed CM4 USB bug. The real cause was in `station-manager` (a serial `open()` corrupting the port; fixed by pyserial), so the kernel version is irrelevant — remove the freeze. The version-line preference (`PREFERRED_VERSION … = "6.18.%"`) and the watchdog/ikconfig fragment (in the separate `%.bbappend`) stay.

**Files:**
- Delete: `meta-oe5xrx-remotestation/dynamic-layers/raspberrypi/recipes-kernel/linux/linux-raspberrypi_6.18.bbappend`

**Interfaces:**
- Consumes: nothing.
- Produces: an RPi kernel that follows meta-raspberrypi's `wrynose` provider (no local SRCREV override); `linux-raspberrypi_%.bbappend` fragment still applies.

- [ ] **Step 1: Confirm the file's only content is the pin**

Run: `cat meta-oe5xrx-remotestation/dynamic-layers/raspberrypi/recipes-kernel/linux/linux-raspberrypi_6.18.bbappend`
Expected: only the `# CM4 USB fix` comment block + `LINUX_VERSION = "6.18.39"` + `SRCREV_machine = "60ea684a…"`. If it contains anything else (a SRC_URI fragment etc.), STOP and report — do not delete blindly.

- [ ] **Step 2: Delete the file**

```bash
git rm meta-oe5xrx-remotestation/dynamic-layers/raspberrypi/recipes-kernel/linux/linux-raspberrypi_6.18.bbappend
```

- [ ] **Step 3: Verify both kas configs still parse and the deliberate pins survive**

```bash
source ~/OE5XRX/.kas-venv/bin/activate
kas dump qemux86-64.yml     >/dev/null && echo "x86 parse OK"
kas dump raspberrypi4-64.yml >/dev/null && echo "rpi parse OK"
# the freeze is gone …
! grep -rq 'SRCREV_machine *= *"60ea684a' meta-oe5xrx-remotestation/ && echo "RPi SRCREV pin gone OK"
# … but the parity line-pins and the fragment stay:
grep -q 'PREFERRED_VERSION_linux-raspberrypi = "6.18.%"' oe5xrx.yml && echo "line-pin kept OK"
grep -q 'oe5xrx-watchdog.cfg' meta-oe5xrx-remotestation/recipes-kernel/linux/linux-raspberrypi_%.bbappend && echo "fragment kept OK"
```
Expected: all five OK lines print.

- [ ] **Step 4: Commit**

```bash
git commit -m "feat(kernel): drop phantom RPi 6.18.39 pin (real fix was pyserial)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Generate and commit the kas lockfile

Pin every kas-managed layer repo to an exact commit so local/remote/CI resolve identical sources → deterministic recipes (incl. the kernel SRCREV via the pinned providers), no more sstate drift-misses, no "Using branch without commit … unsafe" warnings.

**Files:**
- Create: `oe5xrx.lock.yml` (generated)

**Interfaces:**
- Consumes: `oe5xrx.yml` repo list.
- Produces: `oe5xrx.lock.yml` — kas auto-loads the sibling `<name>.lock.yml`, so no reference change is needed in `oe5xrx.yml`.

- [ ] **Step 1: Generate the lockfile**

```bash
source ~/OE5XRX/.kas-venv/bin/activate
kas dump --lock --update --inplace oe5xrx.yml
ls -l oe5xrx.lock.yml
```
Expected: `oe5xrx.lock.yml` created, containing an `overrides:` / `repos:` block with `commit:` values for bitbake, openembedded-core, meta-yocto, meta-openembedded (and raspberrypi via the include).

- [ ] **Step 2: Verify it is valid YAML and NOT gitignored**

```bash
yamllint -d '{extends: default, rules: {line-length: disable, document-start: disable}}' oe5xrx.lock.yml && echo "yaml OK"
git check-ignore oe5xrx.lock.yml && echo "!! IGNORED — fix .gitignore" || echo "tracked OK"
```
Expected: `yaml OK` and `tracked OK`.

- [ ] **Step 3: Verify determinism + that the lock is consumed (no unsafe-branch warning)**

```bash
source ~/OE5XRX/.kas-venv/bin/activate
# re-dumping the lock must be a no-op (deterministic)
cp oe5xrx.lock.yml /tmp/lock.a
kas dump --lock --update --inplace oe5xrx.yml
diff -q /tmp/lock.a oe5xrx.lock.yml && echo "deterministic OK"
# a plain dump must no longer warn about branch-without-commit
kas dump qemux86-64.yml 2>&1 | grep -i 'unsafe\|without commit' && { echo "FAIL: still unsafe"; exit 1; } || echo "no unsafe-branch warning OK"
```
Expected: `deterministic OK` and `no unsafe-branch warning OK`.

- [ ] **Step 4: Commit**

```bash
git add oe5xrx.lock.yml
git commit -m "feat(cache): pin layers via kas lockfile (deterministic sstate)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Enable shallow git fetch

With SRCREVs now pinned (Task 2), fetch only the pinned commit instead of the full `--mirror` history — turns the multi-GB kernel clone (85+ min over sshfs) into an MB-sized shallow tarball. `DL_DIR` stays shared.

**Files:**
- Modify: `oe5xrx.yml` (add `BB_GIT_SHALLOW = "1"` to the `local_conf_header: base:` block)

**Interfaces:**
- Consumes: the lockfile's pinned SRCREVs.
- Produces: shallow source clones in the shared `DL_DIR`.

- [ ] **Step 1: Add the setting**

Add this line to the `local_conf_header: base: |` block in `oe5xrx.yml`, right after the `BB_SIGNATURE_HANDLER = "OEBasicHash"` line:

```
    # Shallow git fetch: only the lockfile-pinned commit, not full history
    # (the linux-yocto --mirror clone was multi-GB / 85+ min over sshfs).
    BB_GIT_SHALLOW = "1"
```

- [ ] **Step 2: Verify it parses and is present**

```bash
source ~/OE5XRX/.kas-venv/bin/activate
kas dump qemux86-64.yml >/dev/null && echo "parse OK"
grep -q 'BB_GIT_SHALLOW = "1"' oe5xrx.yml && echo "shallow set OK"
```
Expected: both OK.

- [ ] **Step 3: Commit**

```bash
git add oe5xrx.yml
git commit -m "feat(cache): shallow git fetch (BB_GIT_SHALLOW) for tiny kernel fetch

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: [HUMAN] Build-validate C1+C2 (x86 + RPi) — GATE

**Not a subagent task.** A human runs the real builds; the controller pauses here and only proceeds once the gate passes. This validates that un-pinning + lockfile + shallow together still produce buildable, bootable images and select a sane kernel version. Config parse checks in Tasks 1-3 do not catch version-selection or boot regressions.

- [ ] **Step 1: Clean the aborted partial clone from the mirror**

The interrupted 85-min clone left a partial `linux-yocto` mirror (no `.done`) + stale `.lock`. With the box mounted (`just local mount`):
```bash
rm -rf /mnt/yocto-shared/downloads/git2/git.yoctoproject.org.linux-yocto.git \
       /mnt/yocto-shared/downloads/git2/git.yoctoproject.org.linux-yocto.git.lock
```

- [ ] **Step 2: Build x86 (warm) + confirm shallow + boot**

Trigger the build (CI or local): `gh workflow run build.yml -f machine=qemux86-64` (or `just local build`).
Expected: the linux-yocto fetch is now small/fast (not a multi-GB clone); build succeeds; note the selected `linux-yocto` version. Boot in QEMU (`just local qemu` / `just remote qemu`) reaches login.

- [ ] **Step 3: Build RPi + confirm kernel version + FM sanity**

Trigger: `gh workflow run build.yml -f machine=raspberrypi4-64`.
Expected: build succeeds; the `linux-raspberrypi` version is meta-raspberrypi's `wrynose` provider (≈6.18.33) — record it. If you have an RPi on the bench, confirm the FM module enumerates over USB (the pyserial fix, not the kernel, is what matters — this is the regression check for removing the pin).

- [ ] **Step 4: Decision gate**

- Both build + x86 boots + (if tested) FM module works → **pass**, continue to Task 5.
- RPi build fails on version selection, or FM/USB regresses → **stop**: reinstate a documented `PREFERRED_VERSION`/pin as needed and update the spec. (This is the one place the un-pin could bite.)

---

### Task 5: Lockfile bump-bot workflow

A scheduled job that regenerates the lockfile against upstream branch tips and opens a PR when it changes — so sources track newest-stable in a reviewed, cache-friendly way.

**Files:**
- Create: `.github/workflows/lockfile-bump.yml`

**Interfaces:**
- Consumes: `oe5xrx.yml`, `oe5xrx.lock.yml`.
- Produces: a PR titled `chore(cache): bump kas lockfile` when the lock changes.

- [ ] **Step 1: Write the workflow**

```yaml
name: Bump kas lockfile
on:
  schedule:
    - cron: '17 4 * * 1'   # Mondays 04:17 UTC
  workflow_dispatch:
permissions:
  contents: write
  pull-requests: write
jobs:
  bump:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-python@v6
        with:
          python-version: '3.x'
      - name: Install kas
        run: pip install kas
      - name: Regenerate lockfile
        run: kas dump --lock --update --inplace oe5xrx.yml
      - name: Open PR if the lock changed
        uses: peter-evans/create-pull-request@v7
        with:
          add-paths: oe5xrx.lock.yml
          branch: chore/kas-lockfile-bump
          delete-branch: true
          title: 'chore(cache): bump kas lockfile'
          commit-message: |
            chore(cache): bump kas lockfile

            Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
          body: |
            Automated weekly kas lockfile bump to the latest upstream branch
            tips. Review the pinned-commit diff, then merge like a dependency
            update. A build runs on this PR via the normal CI.
```

- [ ] **Step 2: Lint**

```bash
yamllint .github/workflows/lockfile-bump.yml && echo "yamllint OK"
```
Expected: OK (match the repo's yamllint config if stricter — mirror an existing workflow's style).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/lockfile-bump.yml
git commit -m "ci(cache): weekly kas lockfile bump-bot (opens PR on drift)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Cache-prune script + scheduled workflow

Keep the Storage Box from filling up: a scheduled job mounts the box and prunes sstate (keep newest per object) + stale downloads (by age, never the current ones) + partial/lock leftovers. Dry-run capable.

**Files:**
- Create: `scripts/cache-prune.sh`
- Create: `.github/workflows/cache-prune.yml`

**Interfaces:**
- Consumes: a mounted `/mnt/yocto-shared`, `openembedded-core/scripts/sstate-cache-management.py`.
- Produces: pruned `sstate` + `downloads` on the box; prints what it removed (or would, in dry-run).

- [ ] **Step 1: Write `scripts/cache-prune.sh`**

```bash
#!/usr/bin/env bash
# Prune the shared Yocto cache on the mounted Storage Box.
# DRY_RUN=1 (default) lists what would be removed; DRY_RUN=0 deletes.
set -euo pipefail
MIRROR="${MIRROR:-/mnt/yocto-shared}"
OE_CORE="${OE_CORE:-openembedded-core}"
DL_AGE_DAYS="${DL_AGE_DAYS:-45}"
DRY_RUN="${DRY_RUN:-1}"
mountpoint -q "$MIRROR" || { echo "error: $MIRROR not mounted" >&2; exit 1; }

echo "== leftovers: partial clones / stale locks =="
find "$MIRROR/downloads/git2" -maxdepth 1 -name '*.lock' -print $( [ "$DRY_RUN" = 1 ] || printf -- -delete ) 2>/dev/null || true

echo "== sstate: remove older duplicates (keep newest per object) =="
sstate_mgmt="$OE_CORE/scripts/sstate-cache-management.py"
[ -f "$sstate_mgmt" ] || sstate_mgmt="$OE_CORE/scripts/sstate-cache-management.sh"
if [ "$DRY_RUN" = 1 ]; then
  python3 "$sstate_mgmt" --cache-dir="$MIRROR/sstate" --remove-duplicated || true
else
  python3 "$sstate_mgmt" --cache-dir="$MIRROR/sstate" --remove-duplicated --yes
fi

echo "== downloads: stale files not accessed in > ${DL_AGE_DAYS} days =="
if [ "$DRY_RUN" = 1 ]; then
  find "$MIRROR/downloads" -type f -atime +"$DL_AGE_DAYS" -print | head -50
  echo "(dry-run: $(find "$MIRROR/downloads" -type f -atime +"$DL_AGE_DAYS" | wc -l) files would be removed)"
else
  find "$MIRROR/downloads" -type f -atime +"$DL_AGE_DAYS" -delete
fi
echo "cache-prune done (DRY_RUN=$DRY_RUN)"
```
Then `chmod +x scripts/cache-prune.sh`.

- [ ] **Step 2: shellcheck the script**

```bash
shellcheck -e SC1091 -e SC2039 scripts/cache-prune.sh && echo "shellcheck OK"
```
Expected: OK. Fix any real findings (the `find … $(...)` conditional-flag trick may trip a warning — if so, replace it with an explicit `if [ "$DRY_RUN" = 1 ]; then find … -print; else find … -delete; fi` block for the leftovers step too).

- [ ] **Step 3: Write `.github/workflows/cache-prune.yml`**

Model the box-mount on `build.yml` (bws-fetch → on-demand server or a runner with sshfs). Reuse the exact bws + sshfs steps from `build.yml` lines ~154-253. Sketch:

```yaml
name: Prune shared cache
on:
  schedule:
    - cron: '43 3 * * *'   # nightly 03:43 UTC
  workflow_dispatch:
    inputs:
      dry_run:
        description: 'List only (1) or delete (0)'
        default: '1'
jobs:
  prune:
    runs-on: ubuntu-latest
    env:
      BWS_ACCESS_TOKEN: ${{ secrets.BWS_ACCESS_TOKEN }}
    steps:
      - uses: actions/checkout@v6
      # --- fetch storagebox creds + sshfs-mount /mnt/yocto-shared ---
      # (copy the "Fetch Storage Box creds" + "Mount shared Yocto cache"
      #  steps from build.yml verbatim; they already produce a mount at
      #  /mnt/yocto-shared on the runner/box)
      - name: Checkout openembedded-core (for the prune script)
        run: |
          pip install kas
          kas checkout oe5xrx.yml   # populates openembedded-core/ per the lock
      - name: Prune
        run: DRY_RUN='${{ github.event.inputs.dry_run || '1' }}' scripts/cache-prune.sh
```

Note for the implementer: the mount mechanics must match `build.yml` (it mounts on an on-demand server, not the GH runner). Follow `build.yml`'s pattern exactly rather than inventing a new mount path. If the mount there is on the on-demand box, run `cache-prune.sh` over ssh on that box (where `/mnt/yocto-shared` exists).

- [ ] **Step 4: Lint**

```bash
yamllint .github/workflows/cache-prune.yml && echo "yamllint OK"
```

- [ ] **Step 5: Commit**

```bash
git add scripts/cache-prune.sh .github/workflows/cache-prune.yml
git commit -m "ci(cache): scheduled sstate+downloads pruning (dry-run default)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

- [ ] **Step 6: [HUMAN] Dry-run validation**

After merge (or via a branch `workflow_dispatch`), run the prune with `dry_run=1` and inspect the "would remove" list. Confirm it keeps current sstate and only lists old duplicates / stale downloads. Only then consider flipping the schedule to delete (`dry_run=0`).

---

### Task 7: Docs

**Files:**
- Modify: `docs/dev-shared-cache.md`

- [ ] **Step 1: Document the Spec-3 additions**

Append a section to `docs/dev-shared-cache.md` covering: the kas lockfile (deterministic sources; bump via the weekly bot PR or `kas dump --lock --update --inplace oe5xrx.yml`); `BB_GIT_SHALLOW` (small fetches; `DL_DIR` stays shared); the nightly `cache-prune` workflow (sstate `--remove-duplicated` + downloads age-prune; dry-run first; retention via `DL_AGE_DAYS`). Note the kept deliberate pins (station-agent SRCREV; `PREFERRED_VERSION 6.18.%` parity).

- [ ] **Step 2: Commit**

```bash
git add docs/dev-shared-cache.md
git commit -m "docs(cache): document lockfile, shallow fetch, and pruning

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:** C1 → Tasks 1 (pin cleanup), 2 (lockfile), 5 (bump-bot); C2 → Task 3 (+ leftover cleanup in Task 4); C3 → Task 6; build-validation → Task 4 [HUMAN]; docs → Task 7. All spec sections covered.

**Placeholder scan:** the two workflow YAMLs are sketches that explicitly reuse `build.yml`'s proven bws+sshfs mount steps (the implementer copies them verbatim — they exist and are cited by line range) rather than re-inventing an untested mount; `cache-prune.sh` is complete. No TBDs.

**Type/name consistency:** `oe5xrx.lock.yml` (auto-loaded), `BB_GIT_SHALLOW = "1"`, `scripts/cache-prune.sh` (`DRY_RUN`/`DL_AGE_DAYS`/`MIRROR`/`OE_CORE`), the two workflow filenames — used consistently across tasks and the docs.

**Sequencing:** 1 → 2 → 3 (config) → 4 [HUMAN build gate] → 5 → 6 → 7. C2 (3) after C1 lockfile (2) per the shallow-needs-pinned-SRCREV dependency; the human build gate (4) validates 1-3 before the independent workflow/doc tasks.
