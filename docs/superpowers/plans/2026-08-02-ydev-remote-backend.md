# ydev Remote Backend (Plan B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The `just remote …` escalation backend — a laptop-driven, on-demand Hetzner CCX43 that mounts the shared mirror and builds Yocto for you, with triple-net auto-teardown so you never think about shutdown.

**Architecture:** `mod remote` (`remote.just`) → `scripts/ydev/remote-*.sh`. The laptop drives via the `hcloud` CLI + SSH: `up` provisions a labelled box (`managed-by=ydev`), fetches the box creds via `bws` and mounts the mirror (mirroring `build.yml`'s proven Fetch+Mount steps), and installs an idle-watchdog + max-lifetime that make the box self-delete. Session state lives in `.ydev-session`. Every recipe does ONE thing and fails early with a hint (no implicit `up`). CI and ydev servers never touch each other's boxes (label vs delete-by-id).

**Tech Stack:** bash, [hcloud CLI](https://github.com/hetznercloud/cli), ssh/scp/rsync, `bws` (Bitwarden Secrets Manager), sshfs (on the box), systemd timers (on the box), kas + QEMU (on the box).

**Spec:** `docs/superpowers/specs/2026-08-02-ydev-interactive-loop-design.md` (Plan B = §4 "Remote (`mod remote`)" + §5 remote creds + §6 auto-teardown + §6.1 CI/user split + §7 provisioning). **Depends on Plan A** (`justfile`, `mod`, `scripts/ydev/lib.sh`, `.env`) being merged first. **Reference implementation:** `.github/workflows/build.yml` on `main` — the "Fetch Storage Box creds", "Install Yocto build dependencies", "Create yocto build user", "Mount shared Yocto cache" steps are the proven commands to mirror.

## Global Constraints

- **One command = one job; error-with-hint.** `just remote build`/`qemu`/`download`/`shell`/`status`/`down` all **fail with a hint** (`just remote up`) if there's no session box. `up` does NOT run implicitly. (Spec §2)
- **Remote creds = bws** (ephemeral box, nothing persisted locally beyond `.env`): laptop fetches `STORAGE_BOX_HOST`/`USER`/`SSH_PRIVKEY` from Bitwarden project `oe5xrx-yocto-cache` (same commands as build.yml lines 156-183), scp's the key to the box, mounts. (Spec §5)
- **CI/user separation is declarative:** ydev boxes carry `--label managed-by=ydev`. `remote clean`, the idle-watchdog and the nightly cron act STRICTLY on `label_selector=managed-by==ydev` (or self-delete by the box's own id). Never touch CI's `oe5xrx-yocto-builder-*`. (Spec §6.1)
- **Triple-net teardown:** idle-watchdog (systemd timer, self-delete after `YDEV_IDLE_MINUTES` idle) + hard max-lifetime (`YDEV_MAX_HOURS`) + nightly `just remote clean` cron on the M920q. Hetzner bills servers that *exist* → teardown = **delete**, not stop. (Spec §6)
- Mount: box **home** (`user@host:`), port 23, `git config --system --add safe.directory '*'`, sstate push `rsync --no-owner --no-group --no-perms` (all proven in build.yml). Mirror path `/mnt/yocto-shared`.
- **Stay out of PR #55 territory** (no dev-image/guard/agent-mount). Extends only the `just` surface + `scripts/ydev/`.
- CI green: `yamllint`, `shellcheck`. Commits imperative ≤72 chars, `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`, squash-merge.

## File Structure

- `remote.just` (root) — the `remote` module recipes.
- `justfile` — add `mod remote` (one line).
- `scripts/ydev/remote-lib.sh` — session state (`.ydev-session`), `require_session`, `require_env_remote`, `box_ssh`/`box_scp`, `YDEV_LABEL`.
- `scripts/ydev/remote-{up,build,qemu,download,shell,status,down,clean}.sh`.
- `scripts/ydev/box/{watchdog.sh,ydev-idle.service,ydev-idle.timer,ydev-maxlife.sh}` — files shipped to and installed on the box by `up`.
- `docs/ydev-remote.md` — operator doc incl. the nightly-cron backstop crontab line.
- Tests: `tests/ydev/test_remote_*.sh` — dry-run + fake-session + label-selector assembly (no real hcloud/ssh in CI).

**Testability:** `hcloud`/`ssh`/real boxes are absent in CI. Tests set `YDEV_DRYRUN=1` (print commands) + a fake `.ydev-session` to exercise `require_session` hints and command assembly (labels, rsync excludes, self-id). Real provisioning is manual (documented in Task 6).

---

### Task 1: `remote-lib` + `mod remote` + `status` / `down` / `clean`

**Files:**
- Create: `scripts/ydev/remote-lib.sh`, `scripts/ydev/remote-status.sh`, `scripts/ydev/remote-down.sh`, `scripts/ydev/remote-clean.sh`, `remote.just`
- Modify: `justfile` (add `mod remote`)
- Test: `tests/ydev/test_remote_lib.sh`

**Interfaces:**
- Consumes: Plan A `lib.sh` (`die_hint`, `run`, `load_env`, `YDEV_ROOT`).
- Produces: `remote-lib.sh` API — `YDEV_SESSION` (=`${YDEV_ROOT}/.ydev-session`, format `<id> <ip> <iso8601>`), `YDEV_LABEL="managed-by=ydev"`, `session_id`, `session_ip`, `require_session` (die_hint→`just remote up`), `require_env_remote` (checks HCLOUD_TOKEN/BWS_ACCESS_TOKEN/HCLOUD_SSH_KEY_NAME + `hcloud`), `box_ssh <cmd…>`, `box_scp <src> <dst>`. Recipes `just remote status|down|clean`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/ydev/test_remote_lib.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export YDEV_ROOT="$tmp"
# no session -> require_session hint
if err=$( (. scripts/ydev/remote-lib.sh; require_session) 2>&1 ); then echo "FAIL require_session"; exit 1; fi
echo "$err" | grep -q "just remote up" || { echo "FAIL session hint: $err"; exit 1; }
# with fake session -> id/ip parse
printf '12345 1.2.3.4 2026-08-02T00:00:00Z\n' > "$tmp/.ydev-session"
out=$( . scripts/ydev/remote-lib.sh; echo "$(session_id)/$(session_ip)" )
[ "$out" = "12345/1.2.3.4" ] || { echo "FAIL parse: $out"; exit 1; }
# clean uses the strict label selector
out=$(YDEV_DRYRUN=1 HCLOUD_TOKEN=x bash scripts/ydev/remote-clean.sh 2>&1 || true)
echo "$out" | grep -q "managed-by==ydev" || { echo "FAIL clean label: $out"; exit 1; }
# down deletes the session id
out=$(YDEV_DRYRUN=1 HCLOUD_TOKEN=x bash scripts/ydev/remote-down.sh 2>&1 || true)
echo "$out" | grep -q "server delete" && echo "$out" | grep -q "12345" || { echo "FAIL down id: $out"; exit 1; }
echo "PASS test_remote_lib"
```
Then `chmod +x`.

- [ ] **Step 2: Run it — expect FAIL** (files missing).

- [ ] **Step 3: Create `scripts/ydev/remote-lib.sh`**

```bash
# scripts/ydev/remote-lib.sh — remote-backend helpers. Source, don't exec.
# shellcheck shell=bash
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
YDEV_SESSION="${YDEV_ROOT}/.ydev-session"
YDEV_LABEL="managed-by=ydev"

session_id() { [ -f "$YDEV_SESSION" ] && awk '{print $1}' "$YDEV_SESSION" || true; }
session_ip() { [ -f "$YDEV_SESSION" ] && awk '{print $2}' "$YDEV_SESSION" || true; }
require_session() { [ -f "$YDEV_SESSION" ] || die_hint "no ydev session box" "just remote up"; }
require_env_remote() {
  for v in HCLOUD_TOKEN BWS_ACCESS_TOKEN HCLOUD_SSH_KEY_NAME; do
    [ -n "${!v:-}" ] || die_hint "$v not set in .env" "just init  (fill the remote section)"
  done
  command -v hcloud >/dev/null || [ "${YDEV_DRYRUN:-0}" = 1 ] || die_hint "hcloud CLI missing" "install github.com/hetznercloud/cli"
}
box_ssh() { run ssh -o StrictHostKeyChecking=accept-new "root@$(session_ip)" "$@"; }
box_scp() { run scp -o StrictHostKeyChecking=accept-new "$1" "root@$(session_ip):$2"; }
```

- [ ] **Step 4: Create `scripts/ydev/remote-down.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/remote-lib.sh"; load_env
require_session
id=$(session_id)
run hcloud server delete "$id"
rm -f "$YDEV_SESSION"
echo "deleted ydev session box $id"
```

- [ ] **Step 5: Create `scripts/ydev/remote-clean.sh`** (label-scoped — never touches CI)

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/remote-lib.sh"; load_env
# STRICT: only servers carrying our ownership label. CI servers (no such label) are untouched.
ids=$(run hcloud server list -l "managed-by==ydev" -o noheader -o columns=id 2>/dev/null || true)
if [ "${YDEV_DRYRUN:-0}" = 1 ]; then echo "DRYRUN: hcloud server list -l managed-by==ydev  → delete each"; exit 0; fi
[ -n "$ids" ] || { echo "no orphaned ydev boxes"; exit 0; }
for id in $ids; do echo "deleting orphaned ydev box $id"; hcloud server delete "$id" || true; done
rm -f "$YDEV_SESSION"
```

- [ ] **Step 6: Create `scripts/ydev/remote-status.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/remote-lib.sh"; load_env
if [ ! -f "$YDEV_SESSION" ]; then echo "no ydev session (just remote up)"; exit 0; fi
id=$(session_id); ip=$(session_ip); started=$(awk '{print $3}' "$YDEV_SESSION")
echo "session box: id=$id ip=$ip started=$started"
run hcloud server describe "$id" -o 'format={{.Status}} {{.ServerType.Name}} {{.Datacenter.Location.Name}}' 2>/dev/null || echo "(hcloud describe failed — box may be gone; run just remote clean)"
echo "mirror on box:"; box_ssh 'mountpoint -q /mnt/yocto-shared && echo mounted || echo NOT-mounted' 2>/dev/null || true
```

- [ ] **Step 7: Create `remote.just` + add `mod remote` to `justfile`**

`remote.just`:
```make
# `just remote <recipe>` — build on an on-demand Hetzner box (auto-teardown).
set dotenv-load := true

# Show the current session box (uptime ≈ cost, mount state)
status:
    scripts/ydev/remote-status.sh
# Delete the current session box now
down:
    scripts/ydev/remote-down.sh
# Delete ALL orphaned ydev boxes (label-scoped; never touches CI)
clean:
    scripts/ydev/remote-clean.sh
```
Append `mod remote` to `justfile` (after `mod local`).

- [ ] **Step 8: Run the test — expect PASS.** `chmod +x scripts/ydev/remote-*.sh`.

- [ ] **Step 9: Commit**

```bash
git add scripts/ydev/remote-lib.sh scripts/ydev/remote-status.sh scripts/ydev/remote-down.sh scripts/ydev/remote-clean.sh remote.just justfile tests/ydev/test_remote_lib.sh
git commit -m "feat(ydev): remote module scaffolding + status/down/clean (label-scoped)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `just remote up` — provision box + mount mirror

**Files:**
- Create: `scripts/ydev/remote-up.sh`
- Modify: `remote.just` (add `up`)
- Test: `tests/ydev/test_remote_up.sh`

**Interfaces:**
- Consumes: `remote-lib.sh`, `.env` (HCLOUD_TOKEN, BWS_ACCESS_TOKEN, BWS_SERVER_URL, HCLOUD_SSH_KEY_NAME, YDEV_SERVER_TYPE, YDEV_LOCATION).
- Produces: `just remote up` → a running box labelled `managed-by=ydev` with `/mnt/yocto-shared` mounted, a `yocto` build user, and `.ydev-session` written. Idempotent (reuses a live session box).

- [ ] **Step 1: Write the failing test** (dry-run: idempotency + create args + label)

```bash
# tests/ydev/test_remote_up.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export YDEV_ROOT="$tmp" YDEV_DRYRUN=1 HCLOUD_TOKEN=x BWS_ACCESS_TOKEN=y HCLOUD_SSH_KEY_NAME=k
out=$(bash scripts/ydev/remote-up.sh 2>&1 || true)
echo "$out" | grep -q "hcloud server create" || { echo "FAIL create: $out"; exit 1; }
echo "$out" | grep -q -- "--type ccx43" || { echo "FAIL type: $out"; exit 1; }
echo "$out" | grep -q -- "--label managed-by=ydev" || { echo "FAIL label: $out"; exit 1; }
echo "PASS test_remote_up"
```
Then `chmod +x`.

- [ ] **Step 2: Run it — expect FAIL** (remote-up.sh missing).

- [ ] **Step 3: Create `scripts/ydev/remote-up.sh`** (mirrors build.yml's proven Fetch+Deps+User+Mount, laptop-driven)

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/remote-lib.sh"; load_env; require_env_remote
# Idempotent: reuse a live session box.
if [ -f "$YDEV_SESSION" ] && [ "${YDEV_DRYRUN:-0}" != 1 ]; then
  if hcloud server describe "$(session_id)" >/dev/null 2>&1; then
    echo "session box already up: $(session_id) ($(session_ip))"; exit 0
  fi
  echo "stale .ydev-session — recreating"; rm -f "$YDEV_SESSION"
fi
TYPE="${YDEV_SERVER_TYPE:-ccx43}"; LOC="${YDEV_LOCATION:-fsn1}"; NAME="ydev-session"
OUT=$(run hcloud server create --name "$NAME" --type "$TYPE" --image ubuntu-24.04 \
        --ssh-key "$HCLOUD_SSH_KEY_NAME" --location "$LOC" --label "managed-by=ydev" --output json)
[ "${YDEV_DRYRUN:-0}" = 1 ] && { echo "DRYRUN: (would parse id/ip, mount, install watchdog)"; exit 0; }
id=$(jq -r '.server.id' <<<"$OUT"); ip=$(hcloud server ip "$id")
printf '%s %s %s\n' "$id" "$ip" "$(date -u +%FT%TZ)" > "$YDEV_SESSION"
# wait for ssh (mirror build.yml "Wait for SSH")
for i in $(seq 1 30); do ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@$ip" true 2>/dev/null && break; sleep 10; done
# deps + yocto user (verbatim from build.yml "Install Yocto build dependencies" + "Create yocto build user")
ssh "root@$ip" bash -s <<'EOF'
  set -euo pipefail
  sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends gawk wget git diffstat unzip texinfo gcc build-essential \
    chrpath socat cpio python3 python3-pip python3-pexpect xz-utils debianutils iputils-ping python3-git \
    python3-jinja2 python3-subunit zstd liblz4-tool file locales libacl1 sshfs rsync qemu-system-x86 ovmf
  locale-gen en_US.UTF-8
  pip3 install kas --break-system-packages
  id yocto >/dev/null 2>&1 || useradd -m -s /bin/bash yocto
  echo 'yocto ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/yocto
  git config --system --add safe.directory '*'
EOF
# bws-fetch box creds on the LAPTOP (remote=bws), scp key, mount (mirror build.yml Fetch+Mount)
export BWS_SERVER_URL="${BWS_SERVER_URL:-https://vault.bitwarden.eu}"
command -v bws >/dev/null || die_hint "bws CLI missing on this machine" "install bws (needed for the remote backend)"
PROJECT_ID=$(bws project list -o json | jq -r '.[]|select(.name=="oe5xrx-yocto-cache")|.id')
[ -n "$PROJECT_ID" ] || die_hint "BW project oe5xrx-yocto-cache not found" "check BWS_ACCESS_TOKEN read-access"
SECRETS=$(bws secret list -p "$PROJECT_ID" -o json)
BOX_HOST=$(jq -r '.[]|select(.key=="STORAGE_BOX_HOST")|.value' <<<"$SECRETS")
BOX_USER=$(jq -r '.[]|select(.key=="STORAGE_BOX_USER")|.value' <<<"$SECRETS")
KEYFILE=$(mktemp); ( umask 077; jq -r '.[]|select(.key=="STORAGE_BOX_SSH_PRIVKEY")|.value' <<<"$SECRETS" > "$KEYFILE" )
ssh "root@$ip" 'install -d -m700 /root/.ssh'
scp "$KEYFILE" "root@$ip:/root/.ssh/storagebox"; rm -f "$KEYFILE"
ssh "root@$ip" bash -s -- "$BOX_USER" "$BOX_HOST" <<'EOF'
  set -euo pipefail
  BOX_USER="$1"; BOX_HOST="$2"
  chmod 600 /root/.ssh/storagebox
  grep -q '^user_allow_other' /etc/fuse.conf || echo 'user_allow_other' >> /etc/fuse.conf
  mkdir -p /mnt/yocto-shared
  sshfs -p 23 -o IdentityFile=/root/.ssh/storagebox,StrictHostKeyChecking=accept-new \
    -o allow_other,reconnect,ServerAliveInterval=15,ServerAliveCountMax=3 "${BOX_USER}@${BOX_HOST}:" /mnt/yocto-shared
  mkdir -p /mnt/yocto-shared/sstate /mnt/yocto-shared/downloads
  sudo -u yocto sh -c 'touch /mnt/yocto-shared/downloads/.wtest && rm -f /mnt/yocto-shared/downloads/.wtest' && echo "mirror writable"
EOF
echo "ydev session box up: $id ($ip)"
echo "next: just remote build   (watchdog + max-lifetime installed by Task 3's step here)"
```
(Task 3 inserts the watchdog-install call before the final echo.)

- [ ] **Step 4: Add `up` to `remote.just`**

```make
# Provision an on-demand build box + mount the shared mirror (idempotent)
up:
    scripts/ydev/remote-up.sh
```

- [ ] **Step 5: Run the test — expect PASS.** `chmod +x`.

- [ ] **Step 6: Commit** `feat(ydev): remote up — provision box + mount mirror` (+ trailer).

---

### Task 3: On-box auto-teardown (idle-watchdog + max-lifetime)

**Files:**
- Create: `scripts/ydev/box/ydev-watchdog.sh`, `scripts/ydev/box/ydev-idle.timer`, `scripts/ydev/box/ydev-idle.service`
- Modify: `scripts/ydev/remote-up.sh` (ship + install the units, pass `HCLOUD_TOKEN`/`YDEV_IDLE_MINUTES`/`YDEV_MAX_HOURS`)
- Test: `tests/ydev/test_watchdog.sh`

**Interfaces:**
- Consumes: box has `hcloud` (install in Task-2 apt line — add `hcloud`... actually install via curl in the watchdog installer), its own id via Hetzner metadata, and a delete-capable `HCLOUD_TOKEN` in `/etc/ydev/token` (root-only, 0600).
- Produces: the box self-deletes after `YDEV_IDLE_MINUTES` idle OR `YDEV_MAX_HOURS` absolute. Idle = no active sshd session AND no `bitbake` process.

- [ ] **Step 1: Write the failing test** (idle-detection logic, dry-run self-delete)

```bash
# tests/ydev/test_watchdog.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
sh -n scripts/ydev/box/ydev-watchdog.sh || { echo "FAIL syntax"; exit 1; }
# active (fake bitbake present) -> resets idle, does NOT delete
out=$(YDEV_DRYRUN=1 YDEV_TEST_BUSY=1 YDEV_STATE="$(mktemp -d)/s" bash scripts/ydev/box/ydev-watchdog.sh 2>&1)
echo "$out" | grep -qi "busy\|active" || { echo "FAIL busy path: $out"; exit 1; }
echo "$out" | grep -qi "server delete" && { echo "FAIL deleted while busy"; exit 1; }
# idle past threshold -> dry-run self-delete
st="$(mktemp -d)/s"; echo 0 > "$st"   # idle-since epoch 0 = long ago
out=$(YDEV_DRYRUN=1 YDEV_TEST_BUSY=0 YDEV_IDLE_MINUTES=1 YDEV_STATE="$st" YDEV_SELF_ID=999 bash scripts/ydev/box/ydev-watchdog.sh 2>&1)
echo "$out" | grep -q "server delete" && echo "$out" | grep -q "999" || { echo "FAIL idle delete: $out"; exit 1; }
echo "PASS test_watchdog"
```
Then `chmod +x`.

- [ ] **Step 2: Run it — expect FAIL** (watchdog missing).

- [ ] **Step 3: Create `scripts/ydev/box/ydev-watchdog.sh`**

```bash
#!/usr/bin/env bash
# Runs ON the ydev box via a systemd timer. Self-deletes the box when idle.
set -euo pipefail
STATE="${YDEV_STATE:-/var/lib/ydev/idle-since}"
IDLE_MIN="${YDEV_IDLE_MINUTES:-30}"
mkdir -p "$(dirname "$STATE")"
now=$(date +%s)
busy() {
  [ "${YDEV_TEST_BUSY:-}" = 1 ] && return 0
  [ "${YDEV_TEST_BUSY:-}" = 0 ] && return 1
  pgrep -x bitbake >/dev/null && return 0
  who | grep -q . && return 0            # any interactive login/ssh session
  ss -tnH state established '( sport = :ssh )' 2>/dev/null | grep -q . && return 0
  return 1
}
del() {
  id="${YDEV_SELF_ID:-$(curl -s http://169.254.169.254/hetzner/v1/metadata/instance-id)}"
  export HCLOUD_TOKEN="${HCLOUD_TOKEN:-$(cat /etc/ydev/token 2>/dev/null || true)}"
  if [ "${YDEV_DRYRUN:-0}" = 1 ]; then echo "DRYRUN: hcloud server delete $id"; else hcloud server delete "$id"; fi
}
if busy; then echo "busy/active — reset idle timer"; echo "$now" > "$STATE"; exit 0; fi
[ -f "$STATE" ] || echo "$now" > "$STATE"
idle_since=$(cat "$STATE"); idle_min=$(( (now - idle_since) / 60 ))
echo "idle ${idle_min}m / ${IDLE_MIN}m"
[ "$idle_min" -ge "$IDLE_MIN" ] && { echo "idle threshold reached — self-deleting"; del; }
```

- [ ] **Step 4: Create the systemd units** `scripts/ydev/box/ydev-idle.timer` (OnBootSec=5min, OnUnitActiveSec=5min) + `ydev-idle.service` (Type=oneshot, ExecStart=/opt/ydev/ydev-watchdog.sh, EnvironmentFile=/etc/ydev/env). Max-lifetime: the installer also schedules `shutdown`/delete via a `systemd-run --on-active=${YDEV_MAX_HOURS}h` one-shot calling the same `del`.

```ini
# ydev-idle.timer
[Unit]
Description=ydev idle watchdog
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
```
```ini
# ydev-idle.service
[Unit]
Description=ydev idle watchdog (self-delete when idle)
[Service]
Type=oneshot
EnvironmentFile=/etc/ydev/env
ExecStart=/opt/ydev/ydev-watchdog.sh
```

- [ ] **Step 5: Wire installation into `remote-up.sh`** — before the final echo, add a step that: installs `hcloud` on the box, writes `/etc/ydev/token` (0600, the delete-capable `HCLOUD_TOKEN`) + `/etc/ydev/env` (`YDEV_IDLE_MINUTES`, `HCLOUD_TOKEN`), scp's `ydev-watchdog.sh`→`/opt/ydev/`, installs+enables the timer, and arms the max-lifetime:

```bash
scp -r "$(dirname "$0")/box" "root@$ip:/tmp/ydev-box"
ssh "root@$ip" bash -s -- "${YDEV_IDLE_MINUTES:-30}" "${YDEV_MAX_HOURS:-4}" "$HCLOUD_TOKEN" <<'EOF'
  set -euo pipefail
  IDLE=$1; MAXH=$2; TOKEN=$3
  curl -fsSL https://github.com/hetznercloud/cli/releases/latest/download/hcloud-linux-amd64.tar.gz | tar xz -C /usr/local/bin hcloud
  install -d -m700 /etc/ydev /opt/ydev
  printf 'YDEV_IDLE_MINUTES=%s\nHCLOUD_TOKEN=%s\n' "$IDLE" "$TOKEN" > /etc/ydev/env; chmod 600 /etc/ydev/env
  printf '%s' "$TOKEN" > /etc/ydev/token; chmod 600 /etc/ydev/token
  install -m755 /tmp/ydev-box/ydev-watchdog.sh /opt/ydev/ydev-watchdog.sh
  install -m644 /tmp/ydev-box/ydev-idle.service /etc/systemd/system/
  install -m644 /tmp/ydev-box/ydev-idle.timer   /etc/systemd/system/
  systemctl daemon-reload; systemctl enable --now ydev-idle.timer
  # hard max-lifetime: self-delete after MAXH hours no matter what
  systemd-run --on-active="${MAXH}h" --unit=ydev-maxlife \
    /bin/sh -c 'export HCLOUD_TOKEN=$(cat /etc/ydev/token); hcloud server delete $(curl -s http://169.254.169.254/hetzner/v1/metadata/instance-id)'
EOF
echo "auto-teardown armed: idle ${YDEV_IDLE_MINUTES:-30}m, max ${YDEV_MAX_HOURS:-4}h"
```

- [ ] **Step 6: Run the test — expect PASS.** `chmod +x scripts/ydev/box/ydev-watchdog.sh`.

- [ ] **Step 7: Commit** `feat(ydev): on-box idle-watchdog + max-lifetime auto-teardown` (+ trailer).

---

### Task 4: `just remote build` + `just remote download`

**Files:**
- Create: `scripts/ydev/remote-build.sh`, `scripts/ydev/remote-download.sh`
- Modify: `remote.just`
- Test: `tests/ydev/test_remote_build.sh`

**Interfaces:**
- Consumes: `remote-lib.sh` (`require_session`, `session_ip`, `box_ssh`). Produces: `just remote build [machine=qemux86-64]` (rsync source up → build as `yocto` → push sstate delta) and `just remote download [machine=qemux86-64]` (rsync deploy images → `dist/<machine>/`).

- [ ] **Step 1: Write the failing test**

```bash
# tests/ydev/test_remote_build.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; export YDEV_ROOT="$tmp"
# no session -> hint
if err=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh 2>&1); then echo "FAIL should exit"; exit 1; fi
echo "$err" | grep -q "just remote up" || { echo "FAIL hint: $err"; exit 1; }
# with session -> dry-run rsync (excludes build/) + kas build as yocto
printf '1 1.2.3.4 t\n' > "$tmp/.ydev-session"
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh raspberrypi4-64 2>&1)
echo "$out" | grep -q "rsync" && echo "$out" | grep -q -- "--exclude" || { echo "FAIL rsync: $out"; exit 1; }
echo "$out" | grep -q "kas build raspberrypi4-64.yml" || { echo "FAIL kas: $out"; exit 1; }
echo "PASS test_remote_build"
```
Then `chmod +x`.

- [ ] **Step 2: Run it — expect FAIL.**

- [ ] **Step 3: Create `scripts/ydev/remote-build.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/remote-lib.sh"; load_env; require_session
machine="${1:-qemux86-64}"
case "$machine" in qemux86-64|raspberrypi4-64) ;; *) die_hint "unknown machine '$machine'" "qemux86-64 | raspberrypi4-64";; esac
ip=$(session_ip)
# sync source to the yocto user's home (exclude local build output)
run rsync -az --delete --exclude 'build/' --exclude '.git/' --exclude 'dist/' \
  -e "ssh -o StrictHostKeyChecking=accept-new" "${YDEV_ROOT}/" "root@${ip}:/home/yocto/src/"
run ssh -o StrictHostKeyChecking=accept-new "root@${ip}" bash -s -- "$machine" <<'EOF'
  set -euo pipefail
  m="$1"; chown -R yocto:yocto /home/yocto/src
  sudo -u yocto -H bash -lc "cd ~/src && export PATH=\$HOME/.local/bin:\$PATH && kas build ${m}.yml"
  # keep the mirror warm: push new sstate (single-user box → no owner/group/perms)
  sudo -u yocto rsync -a --no-owner --no-group --no-perms --ignore-existing \
    /home/yocto/src/build/sstate-cache/ /mnt/yocto-shared/sstate/ || true
EOF
echo "remote build done ($machine). Fetch with: just remote download $machine"
```

- [ ] **Step 4: Create `scripts/ydev/remote-download.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/remote-lib.sh"; load_env; require_session
machine="${1:-qemux86-64}"; ip=$(session_ip)
mkdir -p "${YDEV_ROOT}/dist/${machine}"
run rsync -az -e "ssh -o StrictHostKeyChecking=accept-new" \
  --include='*/' --include='*.wic' --include='*.wic.*' --include='*.ext4' \
  --include='bzImage*' --include='*.dtb' --include='*.qemuboot.conf' --exclude='*' \
  "root@${ip}:/home/yocto/src/build/tmp/deploy/images/${machine}/" "${YDEV_ROOT}/dist/${machine}/"
echo "downloaded → dist/${machine}/"
```

- [ ] **Step 5: Add to `remote.just`**

```make
# Build on the session box against the mirror (fails if no box)
build machine="qemux86-64":
    scripts/ydev/remote-build.sh {{machine}}
# Download the built images from the box to dist/<machine>/
download machine="qemux86-64":
    scripts/ydev/remote-download.sh {{machine}}
```

- [ ] **Step 6: Run the test — expect PASS.** `chmod +x`.

- [ ] **Step 7: Commit** `feat(ydev): remote build (source sync + sstate push) + download` (+ trailer).

---

### Task 5: `just remote qemu` + `just remote shell`

**Files:**
- Create: `scripts/ydev/remote-qemu.sh`, `scripts/ydev/remote-shell.sh`
- Modify: `remote.just`
- Test: `tests/ydev/test_remote_qemu.sh`

**Interfaces:**
- Consumes: `remote-lib.sh`. Produces: `just remote qemu` (boots the box's built qemux86-64 image, serial over SSH via `ssh -t`) and `just remote shell` (interactive `ssh -t` into the box).

- [ ] **Step 1: Write the failing test**

```bash
# tests/ydev/test_remote_qemu.sh
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; export YDEV_ROOT="$tmp"
if err=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-qemu.sh 2>&1); then echo "FAIL should exit"; exit 1; fi
echo "$err" | grep -q "just remote up" || { echo "FAIL hint: $err"; exit 1; }
printf '1 1.2.3.4 t\n' > "$tmp/.ydev-session"
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-qemu.sh 2>&1)
echo "$out" | grep -q "run-qemu.sh" || { echo "FAIL run-qemu: $out"; exit 1; }
echo "PASS test_remote_qemu"
```
Then `chmod +x`.

- [ ] **Step 2: Run it — expect FAIL.**

- [ ] **Step 3: Create `scripts/ydev/remote-qemu.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/remote-lib.sh"; load_env; require_session
ip=$(session_ip)
# run-qemu.sh boots the local build's qemux86-64 wic; -t for the serial console over SSH.
run ssh -t -o StrictHostKeyChecking=accept-new "root@${ip}" \
  "sudo -u yocto -H bash -lc 'cd ~/src && scripts/run-qemu.sh'"
```

- [ ] **Step 4: Create `scripts/ydev/remote-shell.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/remote-lib.sh"; load_env; require_session
run ssh -t -o StrictHostKeyChecking=accept-new "root@$(session_ip)"
```

- [ ] **Step 5: Add to `remote.just`**

```make
# Boot the box's built qemux86-64 image, serial over SSH
qemu:
    scripts/ydev/remote-qemu.sh
# Interactive shell on the session box
shell:
    scripts/ydev/remote-shell.sh
```

- [ ] **Step 6: Run the test — expect PASS.** `chmod +x`.

- [ ] **Step 7: Commit** `feat(ydev): remote qemu (serial over ssh) + shell` (+ trailer).

---

### Task 6: Operator doc + nightly-cron backstop

**Files:**
- Create: `docs/ydev-remote.md`

**Interfaces:** Produces the operator runbook + the nightly `just remote clean` crontab line (the third teardown net, on the M920q).

- [ ] **Step 1: Write `docs/ydev-remote.md`** — covers: `.env` remote vars; `just remote up → build → qemu/download → down`; the triple-net teardown (idle/max/nightly); the nightly cron backstop:

```markdown
# ydev remote backend

## Setup
`just init` → fill the remote section of `.env` (HCLOUD_TOKEN [project 2],
BWS_ACCESS_TOKEN, BWS_SERVER_URL, HCLOUD_SSH_KEY_NAME, optional YDEV_*).
`just doctor` (needs hcloud + bws for remote).

## Loop
`just remote up` → `just remote build [machine]` → `just remote qemu` |
`just remote download [machine]` → `just remote down`. `just remote status`
shows uptime (≈cost); `just remote clean` kills orphaned ydev boxes.

## Auto-teardown (you never have to `down`)
1. Idle-watchdog: box self-deletes after YDEV_IDLE_MINUTES idle.
2. Max-lifetime: self-delete after YDEV_MAX_HOURS regardless.
3. Nightly backstop — add to your M920q crontab:
   `0 3 * * * cd /path/to/linux-image && just remote clean >/dev/null 2>&1`

CI build servers (label-less / `oe5xrx-yocto-builder-*`) are never touched:
clean is strictly `label_selector=managed-by==ydev`.
```

- [ ] **Step 2: Commit** `docs(ydev): remote backend runbook + nightly-clean backstop` (+ trailer).

---

## Self-Review

**Spec coverage (Plan B):**
- §4 `mod remote`: `up`→T2, `build`→T4, `qemu`→T5, `download`→T4, `shell`→T5, `status`/`down`/`clean`→T1 ✓
- §5 remote creds = bws (fetch host/user/privkey, key→mode-600 file, scp, mount) → T2 (mirrors build.yml) ✓
- §6 triple-net teardown: idle-watchdog + max-lifetime → T3; nightly cron → T6 ✓
- §6.1 CI/user split: `managed-by=ydev` label on create (T2), strict label-scoped `clean` (T1), self-delete-by-id (T3) → CI untouched ✓
- §7 provisioning/dataflow (create→deps→user→mount→build→download→down; cross-project mount; build/tmp local on box; mirror read+push) → T2/T4 ✓
- §2 one-job + error-with-hint (`require_session` everywhere) → T1/T4/T5 ✓
- Out of PR #55 territory (no dev-image/guard) ✓

**Placeholder scan:** no TBD/TODO. Provisioning mirrors build.yml's proven, on-`main` commands (referenced + transcribed). Real hcloud/ssh/box actions are inherently manual (no hcloud/box in CI) — covered by dry-run + fake-session tests + the T6 runbook, not hand-waved.

**Type/name consistency:** `remote-lib.sh` API (`session_id`/`session_ip`/`require_session`/`require_env_remote`/`box_ssh`/`box_scp`/`YDEV_SESSION`/`YDEV_LABEL`) used identically across T1–T5. Label string `managed-by=ydev` (create) / `managed-by==ydev` (selector) consistent T1↔T2↔T3. `.ydev-session` format `<id> <ip> <iso8601>` consistent. Machine names + kas invocation match Plan A + the kas configs. Watchdog env (`YDEV_IDLE_MINUTES`/`YDEV_MAX_HOURS`/`HCLOUD_TOKEN`/`YDEV_STATE`/`YDEV_SELF_ID`/`YDEV_TEST_BUSY`) consistent T3 ↔ its test.
