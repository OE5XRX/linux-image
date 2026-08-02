# ydev Local Loop (Plan A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `just`-driven **local** Yocto dev loop — build against the warm shared mirror + boot in QEMU + flash the RPi image — plus the shared scaffolding (`justfile`, `.env`, `init`, `doctor`) the remote backend (Plan B) will extend.

**Architecture:** Thin `justfile` (top-level `init`/`doctor` + `mod local`) → recipes call small `scripts/ydev/*.sh` scripts (real logic, `bash`). `mod local` = `local.just` (`just local mount|umount|build|qemu|flash`). Local mount uses a locally-stored Storage Box key (no BW token on the laptop); kas already auto-detects `/mnt/yocto-shared` (Spec 1). Recipes do ONE thing and fail early with an actionable hint.

**Tech Stack:** [just](https://just.systems) ≥ 1.31 (modules), bash, sshfs, kas, QEMU (via existing `scripts/run-qemu.sh`), lsblk/findmnt/dd (flash).

**Spec:** `docs/superpowers/specs/2026-08-02-ydev-interactive-loop-design.md` (Plan A = §3 scaffolding + §4 "Lokal (`mod local`)" + §5 local creds + §8 error handling + §10 testing). The `mod remote` half is **Plan B**.

## Global Constraints

- **One command = one job.** No recipe performs another intent implicitly. Missing precondition → exit non-zero with a hint naming the fix (`just local mount`, `just init`, etc.). (Spec §2)
- **Both backends are just-modules** — `just local …` (this plan) / `just remote …` (Plan B). Only `init`/`doctor` are top-level. Bare `just` → `just --list`. (Spec §2/§3)
- **Local creds = local key**, no BW token on the laptop: `~/.ssh/storagebox` (the `STORAGE_BOX_SSH_PRIVKEY` from Bitwarden), `STORAGE_BOX_HOST`/`STORAGE_BOX_USER` from `.env`. (Spec §5)
- Mount path is `/mnt/yocto-shared`; Hetzner Storage Box SSH/SFTP on **port 23**; mount the box **home** (`user@host:` — NOT `:/`). kas already keys `SSTATE_MIRRORS`/`DL_DIR` off `os.path.ismount('/mnt/yocto-shared')`. (Spec §5, Spec 1)
- Logic lives in `scripts/ydev/*.sh` (justfile stays thin) — matches the repo convention. `.env`/`dist/` git-ignored.
- **Stay out of PR #55 territory:** no dev-image, no prod-safety-guard, no agent-live-mount, no `dev-*` recipes. `scripts/run-qemu.sh` is used as-is (not modified). (Spec §1/§9)
- CI (`ci.yml`) must stay green: `yamllint`, `shellcheck`. Commit subject imperative ≤72 chars. End commits with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Squash-merge.

## File Structure

- `justfile` (root) — `set dotenv-load := true`, `_default` (list), `init`, `doctor`, `mod local`.
- `local.just` (root) — the `local` module recipes.
- `scripts/ydev/lib.sh` — shared bash helpers (env load, `die_hint`, dry-run `run`, `mirror_mounted`).
- `scripts/ydev/{init,doctor,local-mount,local-umount,local-build,local-flash}.sh` — recipe logic.
- `.env.example` (tracked) → `.env` (git-ignored).
- `tests/ydev/test_*.sh` — bash tests (dry-run + precondition/hint logic; mirror the existing `tests/dev-loop/test_dev_launch.sh` plain-bash style).
- `.gitignore` — add `.env`, `/dist/`, `.ydev-session`.

**Testability note:** `kas`/`sshfs`/`qemu`/real devices aren't available in CI, so tests exercise the *precondition + hint + command-assembly* logic via `YDEV_DRYRUN=1` (print the command instead of running) and `YDEV_FORCE_MOUNTED=1` (fake the mount check). Real build/mount/flash are manual/on-target (documented per task).

---

### Task 1: Shared lib + `.env.example` + `.gitignore`

**Files:**
- Create: `scripts/ydev/lib.sh`
- Create: `.env.example`
- Modify: `.gitignore`
- Test: `tests/ydev/test_lib.sh`

**Interfaces:**
- Produces: `lib.sh` sourced by every `scripts/ydev/*.sh`. Functions: `die_hint <msg> [fix]` (stderr + exit 1), `run <cmd...>` (dry-run aware), `load_env` (source `.env` if present), `mirror_mounted` (mount check, test-overridable). Var `MIRROR_MNT=/mnt/yocto-shared`, `YDEV_ROOT` (repo root).

- [ ] **Step 1: Write the failing test**

```bash
# tests/ydev/test_lib.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
. scripts/ydev/lib.sh

# run(): dry-run prints, does not execute
out=$(YDEV_DRYRUN=1 run echo hello)
[ "$out" = "DRYRUN: echo hello" ] || { echo "FAIL run-dryrun: '$out'"; exit 1; }
out=$(YDEV_DRYRUN=0 run echo hello)
[ "$out" = "hello" ] || { echo "FAIL run-real: '$out'"; exit 1; }

# mirror_mounted(): honours the test override
YDEV_FORCE_MOUNTED=1 mirror_mounted || { echo "FAIL force-mounted"; exit 1; }

# die_hint(): exits 1 and prints msg + fix to stderr
if err=$( (die_hint "boom" "do X") 2>&1 ); then echo "FAIL die_hint exit"; exit 1; fi
echo "$err" | grep -q "boom" || { echo "FAIL die_hint msg"; exit 1; }
echo "$err" | grep -q "do X" || { echo "FAIL die_hint fix"; exit 1; }

echo "PASS test_lib"
```
Then `chmod +x tests/ydev/test_lib.sh`.

- [ ] **Step 2: Run it — expect FAIL** (`bash tests/ydev/test_lib.sh` → fails: `scripts/ydev/lib.sh` missing).

- [ ] **Step 3: Create `scripts/ydev/lib.sh`**

```bash
# scripts/ydev/lib.sh — shared helpers for ydev recipes. Source, don't exec.
# shellcheck shell=bash
YDEV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIRROR_MNT="${YDEV_MIRROR_MNT:-/mnt/yocto-shared}"

die_hint() {  # <msg> [fix]
  echo "ydev: error: $1" >&2
  [ -n "${2:-}" ] && echo "  → $2" >&2
  exit 1
}

run() {  # dry-run aware: YDEV_DRYRUN=1 prints instead of executing
  if [ "${YDEV_DRYRUN:-0}" = "1" ]; then echo "DRYRUN: $*"; else "$@"; fi
}

load_env() {  # source .env if present (justfile also dotenv-loads; this covers direct calls)
  [ -f "${YDEV_ROOT}/.env" ] && { set -a; . "${YDEV_ROOT}/.env"; set +a; } || true
}

mirror_mounted() {  # true if the shared mirror is mounted (test override: YDEV_FORCE_MOUNTED=1)
  [ "${YDEV_FORCE_MOUNTED:-0}" = "1" ] && return 0
  mountpoint -q "$MIRROR_MNT"
}
```

- [ ] **Step 4: Create `.env.example`**

```bash
# ydev config — copy to .env (git-ignored) and fill in. `just init` does this.
# --- Local backend (build on this machine against the shared mirror) ---
STORAGE_BOX_HOST=u644097.your-storagebox.de
STORAGE_BOX_USER=u644097
# Put the box PRIVATE key (Bitwarden: STORAGE_BOX_SSH_PRIVKEY) at ~/.ssh/storagebox (chmod 600).
# --- Remote backend (Plan B: `just remote …`) — fill when needed ---
#HCLOUD_TOKEN=
#BWS_ACCESS_TOKEN=
#BWS_SERVER_URL=https://vault.bitwarden.eu
#HCLOUD_SSH_KEY_NAME=
#YDEV_SERVER_TYPE=ccx43
#YDEV_LOCATION=fsn1
#YDEV_IDLE_MINUTES=30
#YDEV_MAX_HOURS=4
```

- [ ] **Step 5: Append to `.gitignore`** (only if not already present): `.env`, `/dist/`, `.ydev-session`.

- [ ] **Step 6: Run the test — expect PASS** (`bash tests/ydev/test_lib.sh` → `PASS test_lib`).

- [ ] **Step 7: Commit**

```bash
git add scripts/ydev/lib.sh .env.example .gitignore tests/ydev/test_lib.sh
git commit -m "feat(ydev): shared lib + .env.example + gitignore

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `justfile` + `just init` + `just doctor`

**Files:**
- Create: `justfile`
- Create: `scripts/ydev/init.sh`, `scripts/ydev/doctor.sh`
- Test: `tests/ydev/test_init.sh`

**Interfaces:**
- Consumes: `lib.sh`.
- Produces: top-level recipes `just` (→ `--list`), `just init`, `just doctor`. `init.sh` copies `.env.example`→`.env` if absent (never overwrites). `doctor.sh` prints pass/fail per check, exits non-zero if any hard check fails.

- [ ] **Step 1: Write the failing test**

```bash
# tests/ydev/test_init.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp .env.example "$tmp/.env.example"
# init creates .env from example when absent
( cd "$tmp" && YDEV_ROOT="$tmp" bash "$OLDPWD/scripts/ydev/init.sh" )
[ -f "$tmp/.env" ] || { echo "FAIL init did not create .env"; exit 1; }
# init does NOT overwrite an existing .env
echo "SENTINEL=1" >> "$tmp/.env"
( cd "$tmp" && YDEV_ROOT="$tmp" bash "$OLDPWD/scripts/ydev/init.sh" )
grep -q SENTINEL "$tmp/.env" || { echo "FAIL init overwrote .env"; exit 1; }
echo "PASS test_init"
```
Then `chmod +x tests/ydev/test_init.sh`.

- [ ] **Step 2: Run it — expect FAIL** (init.sh missing).

- [ ] **Step 3: Create `justfile`**

```make
# OE5XRX linux-image dev commands. `just` (bare) lists everything.
set dotenv-load := true

_default:
    @just --list

# Scaffold .env from .env.example (does not overwrite)
init:
    scripts/ydev/init.sh

# Preflight: report what's missing for local (and remote) use
doctor:
    scripts/ydev/doctor.sh
```
(`mod local` is added to the justfile in Task 3, once `local.just` exists — a `mod` line pointing at a missing module file makes `just` error.)

- [ ] **Step 4: Create `scripts/ydev/init.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
if [ -f "${YDEV_ROOT}/.env" ]; then
  echo "ydev: .env already exists — leaving it untouched"
  exit 0
fi
cp "${YDEV_ROOT}/.env.example" "${YDEV_ROOT}/.env"
echo "ydev: wrote .env — fill in STORAGE_BOX_HOST/USER and place ~/.ssh/storagebox, then run: just doctor"
```
Then `chmod +x`.

- [ ] **Step 5: Create `scripts/ydev/doctor.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"; load_env
fail=0
chk() { if eval "$2" >/dev/null 2>&1; then echo "ok   $1"; else echo "MISS $1 — $3"; fail=1; fi; }
echo "== ydev doctor =="
chk "just >= 1.31"      'v=$(just --version | grep -oE "[0-9]+\.[0-9]+" | head -1); [ "$(printf "%s\n1.31" "$v" | sort -V | head -1)" = "1.31" ]' "install/upgrade just"
chk "kas"               'command -v kas'                         "pip install kas"
chk "sshfs"             'command -v sshfs'                       "sudo apt install sshfs"
chk ".env present"      '[ -f "${YDEV_ROOT}/.env" ]'            "just init"
chk "STORAGE_BOX_HOST"  '[ -n "${STORAGE_BOX_HOST:-}" ]'        "set it in .env"
chk "STORAGE_BOX_USER"  '[ -n "${STORAGE_BOX_USER:-}" ]'        "set it in .env"
chk "box key"           '[ -f "${HOME}/.ssh/storagebox" ]'      "put STORAGE_BOX_SSH_PRIVKEY there (chmod 600)"
# remote extras are optional here (Plan B); report as info only
for t in hcloud bws; do command -v "$t" >/dev/null 2>&1 && echo "ok   $t (remote)" || echo "info $t not installed (only needed for 'just remote …')"; done
[ "$fail" = 0 ] && echo "doctor: local loop ready" || { echo "doctor: fix the MISS items above"; exit 1; }
```
Then `chmod +x`.

- [ ] **Step 6: Run the test — expect PASS.** Also run `bash -n justfile` is N/A; instead verify justfile parses if `just` is available: `just --list` (skip if `just` not installed — CI/shellcheck still lints the scripts).

- [ ] **Step 7: Commit**

```bash
git add justfile scripts/ydev/init.sh scripts/ydev/doctor.sh tests/ydev/test_init.sh
git commit -m "feat(ydev): justfile + init + doctor (top-level)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `mod local` — `mount` / `umount`

**Files:**
- Create: `local.just`
- Create: `scripts/ydev/local-mount.sh`, `scripts/ydev/local-umount.sh`
- Modify: `justfile` (append `mod local`)
- Test: `tests/ydev/test_local_mount.sh`

**Interfaces:**
- Consumes: `lib.sh`, `.env`.
- Produces: `just local mount` / `just local umount`. Mount is idempotent (skip if already mounted); creates `/mnt/yocto-shared` owned by `$USER` (one-time sudo) then sshfs-mounts as the user (no allow_other needed); fails with hints if key/vars/sshfs missing.

- [ ] **Step 1: Write the failing test** (dry-run: asserts the sshfs command is assembled correctly + preconditions)

```bash
# tests/ydev/test_local_mount.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmpkey="$(mktemp)"; trap 'rm -f "$tmpkey"' EXIT
export STORAGE_BOX_HOST=u1.example STORAGE_BOX_USER=u1
# missing key -> must exit non-zero AND print the hint
if err=$(YDEV_DRYRUN=1 YDEV_KEY="$tmpkey.nope" bash scripts/ydev/local-mount.sh 2>&1); then echo "FAIL missing-key should exit nonzero: $err"; exit 1; fi
echo "$err" | grep -q "storagebox" || { echo "FAIL missing-key hint: $err"; exit 1; }
# with key -> dry-run prints an sshfs to the box HOME (host:) on port 23
out=$(YDEV_DRYRUN=1 YDEV_KEY="$tmpkey" YDEV_FORCE_MOUNTED=0 bash scripts/ydev/local-mount.sh 2>&1 || true)
echo "$out" | grep -q -- "-p 23" || { echo "FAIL port: $out"; exit 1; }
echo "$out" | grep -q "u1@u1.example:" || { echo "FAIL target host: $out"; exit 1; }
echo "$out" | grep -q "/mnt/yocto-shared" || { echo "FAIL mnt: $out"; exit 1; }
echo "PASS test_local_mount"
```
Then `chmod +x`. (Note: uses `YDEV_KEY` override so the test needn't touch `~/.ssh`.)

- [ ] **Step 2: Run it — expect FAIL** (local-mount.sh missing).

- [ ] **Step 3: Create `scripts/ydev/local-mount.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"; load_env
KEY="${YDEV_KEY:-${HOME}/.ssh/storagebox}"
if mirror_mounted; then echo "already mounted: $MIRROR_MNT"; exit 0; fi
[ -n "${STORAGE_BOX_HOST:-}" ] && [ -n "${STORAGE_BOX_USER:-}" ] || die_hint "STORAGE_BOX_HOST/USER not set in .env" "just init  (then edit .env)"
[ -f "$KEY" ] || die_hint "box key $KEY missing" "save Bitwarden STORAGE_BOX_SSH_PRIVKEY there, chmod 600"
command -v sshfs >/dev/null || die_hint "sshfs not installed" "sudo apt install sshfs"
[ -d "$MIRROR_MNT" ] || run sudo install -d -o "${USER}" "$MIRROR_MNT"
# Box home (host: not :/) on port 23; user-owned mount → no allow_other needed.
run sshfs -p 23 \
  -o IdentityFile="$KEY",StrictHostKeyChecking=accept-new,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 \
  "${STORAGE_BOX_USER}@${STORAGE_BOX_HOST}:" "$MIRROR_MNT"
echo "mounted $MIRROR_MNT"
```
Then `chmod +x`.

- [ ] **Step 4: Create `scripts/ydev/local-umount.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
if mountpoint -q "$MIRROR_MNT"; then run fusermount3 -u "$MIRROR_MNT" 2>/dev/null || run fusermount -u "$MIRROR_MNT"; echo "unmounted $MIRROR_MNT"; else echo "not mounted: $MIRROR_MNT"; fi
```
Then `chmod +x`.

- [ ] **Step 5: Add recipes to `local.just`**

```make
# `just local <recipe>` — build/boot/flash on THIS machine.
set dotenv-load := true

# Mount the shared Storage Box mirror at /mnt/yocto-shared (idempotent)
mount:
    scripts/ydev/local-mount.sh

# Unmount the shared mirror
umount:
    scripts/ydev/local-umount.sh
```

Then append `mod local` to `justfile` (after the `doctor` recipe) so `just local …` resolves:
```make
mod local
```

- [ ] **Step 6: Run the test — expect PASS.** If `just` is installed, also confirm `just --list` shows the `local` module (no "module file not found" error).

- [ ] **Step 7: Commit**

```bash
git add local.just scripts/ydev/local-mount.sh scripts/ydev/local-umount.sh tests/ydev/test_local_mount.sh
git commit -m "feat(ydev): local mount/umount of the shared mirror

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `just local build` + `just local qemu`

**Files:**
- Create: `scripts/ydev/local-build.sh`
- Modify: `local.just` (add `build`, `qemu`)
- Test: `tests/ydev/test_local_build.sh`

**Interfaces:**
- Consumes: `lib.sh`, `mirror_mounted`, existing `scripts/run-qemu.sh`.
- Produces: `just local build [machine=qemux86-64]` (fails with hint if mirror not mounted; else `kas build <machine>.yml`); `just local qemu` (calls `scripts/run-qemu.sh`).

- [ ] **Step 1: Write the failing test**

```bash
# tests/ydev/test_local_build.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# not mounted -> fails with a hint to `just local mount`
if err=$(YDEV_FORCE_MOUNTED=0 YDEV_DRYRUN=1 bash scripts/ydev/local-build.sh 2>&1); then echo "FAIL should exit nonzero"; exit 1; fi
echo "$err" | grep -q "just local mount" || { echo "FAIL mount hint: $err"; exit 1; }
# mounted -> dry-run prints kas build for the default + explicit machine
out=$(YDEV_FORCE_MOUNTED=1 YDEV_DRYRUN=1 bash scripts/ydev/local-build.sh 2>&1)
echo "$out" | grep -q "kas build qemux86-64.yml" || { echo "FAIL default machine: $out"; exit 1; }
out=$(YDEV_FORCE_MOUNTED=1 YDEV_DRYRUN=1 bash scripts/ydev/local-build.sh raspberrypi4-64 2>&1)
echo "$out" | grep -q "kas build raspberrypi4-64.yml" || { echo "FAIL rpi machine: $out"; exit 1; }
echo "PASS test_local_build"
```
Then `chmod +x`.

- [ ] **Step 2: Run it — expect FAIL** (local-build.sh missing).

- [ ] **Step 3: Create `scripts/ydev/local-build.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"; load_env
machine="${1:-qemux86-64}"
case "$machine" in qemux86-64|raspberrypi4-64) ;; *) die_hint "unknown machine '$machine'" "use qemux86-64 or raspberrypi4-64";; esac
mirror_mounted || die_hint "shared mirror not mounted at $MIRROR_MNT" "just local mount"
command -v kas >/dev/null 2>&1 || [ "${YDEV_DRYRUN:-0}" = "1" ] || die_hint "kas not installed" "pip install kas"
run kas build "${machine}.yml"
```
Then `chmod +x`.

- [ ] **Step 4: Add recipes to `local.just`**

```make
# Build an image locally against the warm mirror (fails if not mounted)
build machine="qemux86-64":
    scripts/ydev/local-build.sh {{machine}}

# Boot the built qemux86-64 image locally in QEMU (serial in this terminal)
qemu:
    scripts/run-qemu.sh
```

- [ ] **Step 5: Run the test — expect PASS.**

- [ ] **Step 6: Commit**

```bash
git add scripts/ydev/local-build.sh local.just tests/ydev/test_local_build.sh
git commit -m "feat(ydev): local build (mirror-gated) + qemu

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `just local flash <device>` (RPi, guarded)

**Files:**
- Create: `scripts/ydev/local-flash.sh`
- Modify: `local.just` (add `flash`)
- Test: `tests/ydev/test_local_flash.sh`

**Interfaces:**
- Consumes: `lib.sh`. Produces: `just local flash [device]` — writes the raspberrypi4-64 `.wic` to `<device>` with safety guards; no `<device>` → lists removable candidates + usage.

- [ ] **Step 1: Write the failing test**

```bash
# tests/ydev/test_local_flash.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# no device -> usage + lists devices, exits nonzero
if out=$(bash scripts/ydev/local-flash.sh 2>&1); then echo "FAIL no-device should exit nonzero"; exit 1; fi
echo "$out" | grep -qi "usage" || { echo "FAIL usage: $out"; exit 1; }
# non-block device -> refuse
if err=$(bash scripts/ydev/local-flash.sh /tmp 2>&1); then echo "FAIL /tmp should be refused"; exit 1; fi
echo "$err" | grep -qi "block device" || { echo "FAIL block-check: $err"; exit 1; }
echo "PASS test_local_flash"
```
Then `chmod +x`.

- [ ] **Step 2: Run it — expect FAIL** (local-flash.sh missing).

- [ ] **Step 3: Create `scripts/ydev/local-flash.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"; load_env
dev="${1:-}"
if [ -z "$dev" ]; then
  echo "usage: just local flash <device>   (writes the raspberrypi4-64 .wic)"
  echo "removable block devices:"
  lsblk -dno NAME,SIZE,RM,TRAN,MODEL 2>/dev/null | awk '$3==1 {print "  /dev/"$0}' || true
  exit 1
fi
WIC=$(ls -1 "${YDEV_ROOT}"/build/tmp/deploy/images/raspberrypi4-64/*.rootfs.wic \
             "${YDEV_ROOT}"/dist/raspberrypi4-64/*.wic 2>/dev/null | head -1 || true)
[ -b "$dev" ] || die_hint "$dev is not a block device"
[ -n "$WIC" ] || die_hint "no raspberrypi4-64 .wic found" "just local build raspberrypi4-64  (or just remote download raspberrypi4-64)"
# refuse the disk that carries / (system disk)
rootdisk=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" 2>/dev/null | head -1 || true)
[ -n "$rootdisk" ] && [ "$dev" = "/dev/$rootdisk" ] && die_hint "$dev is the system disk — refusing"
# require removable
[ "$(lsblk -dno RM "$dev" 2>/dev/null || echo 0)" = "1" ] || die_hint "$dev is not removable — refusing (safety)"
echo "About to OVERWRITE $dev with $WIC:"; lsblk "$dev"
read -r -p "Type the device path to confirm: " c
[ "$c" = "$dev" ] || die_hint "confirmation mismatch — aborted"
case "$WIC" in
  *.wic) run sudo dd if="$WIC" of="$dev" bs=4M conv=fsync status=progress ;;
  *) die_hint "unexpected image format: $WIC" "expected a plain .wic" ;;
esac
run sync
echo "flashed $dev"
```
Then `chmod +x`.

- [ ] **Step 4: Add recipe to `local.just`**

```make
# Write the raspberrypi4-64 .wic to an SD/device (guarded). No device -> lists candidates.
flash device="":
    scripts/ydev/local-flash.sh {{device}}
```

- [ ] **Step 5: Run the test — expect PASS.**

- [ ] **Step 6: Manual verification note** (not automated — needs hardware/kas):
  - `just init` → edit `.env` → `just doctor` (all local checks ok).
  - `just local mount` → `just local build` (warm, minutes) → `just local qemu` (boots, serial).
  - `just local flash /dev/sdX` with an SD inserted (guards prompt + confirm).

- [ ] **Step 7: Commit**

```bash
git add scripts/ydev/local-flash.sh local.just tests/ydev/test_local_flash.sh
git commit -m "feat(ydev): local flash (raspberrypi4-64 wic, guarded)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (Plan A scope):**
- §3 structure (justfile thin + `mod local` + `scripts/ydev/` + `.env`) → Tasks 1–3 ✓
- §4 `mod local`: `mount`/`umount` → T3; `build` (mirror-gated) + `qemu` → T4; `flash` (RPi, guarded, lists candidates) → T5 ✓
- §4 setup/health: `init` + `doctor` → T2 ✓; bare `just`→list → T2 ✓
- §5 local creds = local key, no BW token → T3 (`~/.ssh/storagebox`, host/user from `.env`) ✓
- §2 one-job + error-with-hint → every recipe's precondition checks (T3/T4/T5) ✓
- §8 error handling + `doctor` diagnosis → T2/T5 ✓
- §10 testing via dry-run/precondition + manual on-target note → tests in T1–T5 + T5 Step 6 ✓
- §1/§9 stays out of PR #55 (no dev-image/guard/agent-mount; run-qemu.sh unmodified) → File Structure + Constraints ✓
- **Plan B (out of scope here):** `mod remote` (`up`/`build`/`qemu`/`download`/`shell`/`status`/`down`/`clean`) + auto-teardown + `managed-by=ydev` label — separate plan.

**Placeholder scan:** no TBD/TODO; every step has real code. Real build/mount/flash are inherently manual (no kas/hardware in CI) — covered by dry-run tests + the T5 manual note, not hand-waved.

**Type/name consistency:** `lib.sh` API (`die_hint`, `run`, `load_env`, `mirror_mounted`, `MIRROR_MNT`, `YDEV_ROOT`) used identically across T2–T5. Recipe names match the spec (`local mount|umount|build|qemu|flash`, `init`, `doctor`). `YDEV_DRYRUN`/`YDEV_FORCE_MOUNTED`/`YDEV_KEY` test hooks consistent between scripts and tests. Machine names `qemux86-64`/`raspberrypi4-64` match the kas configs.
