# CI Build-Server ydev-Konvergenz — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Den CI-Yocto-Build so umbauen, dass die on-demand Hetzner-Box sich immer selbst beendet (kein Orphan, kein Namenskonflikt) — indem `build.yml` zu einem dünnen GH-hosted Wrapper um die bewährten `scripts/ydev/remote-*`-Skripte wird.

**Architecture:** `build.yml` verliert die drei Jobs (`create-runner`/self-hosted `build`/`cleanup`) und wird EIN `ubuntu-latest`-Job, der die Box über SSH via `scripts/ydev/remote-up.sh` → `remote-build.sh` → `remote-download.sh` → `remote-down.sh` treibt. Die Box armt beim Boot ihren cloud-init self-teardown (idle + max-life + self-heal) — der explizite `remote-down.sh` (`if: always()`) ist der Happy-Path, das cloud-init-Netz fängt Cancellation ab. Eindeutige Box-Namen pro Run killen die Namenskonflikt-Klasse; keine GitHub-Runner-Registrierung mehr.

**Tech Stack:** GitHub Actions (reusable workflow), Bash, Hetzner Cloud CLI (`hcloud`), kas/BitBake (auf der Box), Cloudflare R2 (sstate/downloads-Mirror), Bitwarden Secrets (`bws`).

**Spec:** `docs/superpowers/specs/2026-08-31-ci-ydev-converge-design.md`

## Global Constraints

- **Reusable-Schnittstelle unverändert:** `build.yml` behält `workflow_dispatch` + `workflow_call` + `pull_request`; Inputs exakt `machine` / `release_tag` / `dev_image`; Artifact-Name exakt `yocto-image-<machine>`. Caller `boot-ota-pr.yml` (`dev_image: true`) und `release.yml` (`build-x64`/`build-rpi`) dürfen NICHT brechen.
- **Maschinen:** nur `qemux86-64` und `raspberrypi4-64`.
- **Prod-only-Artifact:** das hochgeladene Artifact darf `oe5xrx-remotestation-dev-image-*` NICHT enthalten (speist `boot-ota-test`, das die Prod-Image booten muss).
- **`dev_image=true` baut BEIDE Targets** (`oe5xrx-remotestation-image` + `oe5xrx-remotestation-dev-image`) in EINEM kas-Lauf (billiger sstate-Delta).
- **Laptop-Semantik von `remote-*.sh` bleibt erhalten:** `--dev` = nur dev-Target; Default = nur prod. Neue CI-Fähigkeiten werden additiv ergänzt, nie durch Umdefinition bestehender Flags.
- **Actions pinnen** mit Commit-SHA + `# vX`-Kommentar (Repo-Konvention; siehe bestehende `build.yml`).
- **Secrets** nur über Job/Step-`env:`-Block, nie als CLI-Arg.
- **CPX-Server-Typ** (shared vCPU) statt `ccx43` — konkreter SKU: `cpx62` (CPX Gen2), via `YDEV_SERVER_TYPE`. (`cpx51` war zunächst geplant, ist aber in `fsn1` nicht mehr bestellbar → im ersten Live-Run auf `cpx62` korrigiert.)
- **CI-Teardown-Defaults:** `YDEV_IDLE_MINUTES=10`, `YDEV_MAX_HOURS=3`.
- Shell: `set -euo pipefail`; Skripte müssen `shellcheck -e SC1091 -e SC2039` sauber sein.
- Commit-Trailer: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

## File Structure

- **Modify** `scripts/ydev/remote-up.sh` — Box-`--name` aus `YDEV_SESSION_NAME` (Default `ydev-session`).
- **Modify** `scripts/ydev/remote-build.sh` — additiver `--both`-Modus (prod+dev in einem kas-Lauf) + `OE5XRX_RELEASE_TAG` bis in die Box-kas-Umgebung weiterreichen (Passthrough).
- **Create** `scripts/ydev/ci-collect-prod-artifacts.sh` — sammelt aus `dist/<machine>/` die Prod-Images in `artifacts/`, schließt `oe5xrx-remotestation-dev-image-*` aus.
- **Modify** `tests/ydev/test_remote_up.sh` — Assertion: `YDEV_SESSION_NAME` → `--name` im Dryrun.
- **Modify** `tests/ydev/test_remote_build.sh` — Assertions: `--both` → beide `--target`; `OE5XRX_RELEASE_TAG`-Durchstich.
- **Create** `tests/ydev/test_ci_collect_prod_artifacts.sh` — Prod-only-Collection.
- **Modify** `.env.example` — `YDEV_SESSION_NAME` dokumentieren.
- **Modify** `.github/workflows/ci.yml` — Job, der `tests/ydev/*.sh` fährt + ydev-Skripte shellchecked (damit die neuen Tests gaten).
- **Rewrite** `.github/workflows/build.yml` — EIN `ubuntu-latest`-Job (Wrapper).
- **Verify only** `.github/workflows/boot-ota-pr.yml`, `.github/workflows/release.yml` — Schnittstelle unverändert.

**Hinweis zur Implementierung:** Der Workflow ruft die Skripte **direkt** (`bash scripts/ydev/remote-up.sh`) statt über `just` — funktional identisch zu `just remote up` (die `remote.just`-Rezepte sind 1:1-Wrapper), spart die `just`-Installation im CI. `load_env` toleriert eine fehlende `.env`; alle Config kommt über den Job-`env:`-Block.

---

### Task 1: Box-Name parametrisieren (`remote-up.sh`)

**Files:**
- Modify: `scripts/ydev/remote-up.sh` (Zeile mit `NAME="ydev-session"`)
- Modify: `tests/ydev/test_remote_up.sh`
- Modify: `.env.example`

**Interfaces:**
- Consumes: nichts.
- Produces: Env-Var `YDEV_SESSION_NAME` (String, Default `ydev-session`) steuert den Hetzner-`--name`. CI setzt sie auf `ci-<run_id>-<run_attempt>-<machine>`.

- [ ] **Step 1: Failing test ergänzen**

In `tests/ydev/test_remote_up.sh` NACH der bestehenden `--type ccx43`-Assertion einfügen:

```bash
# box name is parameterisable (CI passes a unique per-run name)
out2=$(YDEV_SESSION_NAME=ci-42-1-qemux86-64 bash scripts/ydev/remote-up.sh 2>&1 || true)
echo "$out2" | grep -q -- "--name ci-42-1-qemux86-64" || { echo "FAIL custom name: $out2"; exit 1; }
# default is still ydev-session when unset
echo "$out" | grep -q -- "--name ydev-session" || { echo "FAIL default name: $out"; exit 1; }
```

- [ ] **Step 2: Test laufen lassen — muss FAILEN**

Run: `bash tests/ydev/test_remote_up.sh`
Expected: FAIL bei „custom name" (heute ist der Name hartcodiert `ydev-session`, `--name ci-42-1-...` erscheint nicht).

- [ ] **Step 3: `remote-up.sh` anpassen**

Zeile
```bash
TYPE="${YDEV_SERVER_TYPE:-ccx43}"; LOC="${YDEV_LOCATION:-fsn1}"; NAME="ydev-session"
```
ändern zu
```bash
TYPE="${YDEV_SERVER_TYPE:-ccx43}"; LOC="${YDEV_LOCATION:-fsn1}"; NAME="${YDEV_SESSION_NAME:-ydev-session}"
```

- [ ] **Step 4: Test laufen lassen — muss PASSEN**

Run: `bash tests/ydev/test_remote_up.sh`
Expected: `PASS test_remote_up`

- [ ] **Step 5: `.env.example` dokumentieren**

In `.env.example` unter der Remote-Sektion ergänzen (nach `#HCLOUD_SSH_KEY=...`):
```bash
# Hetzner box name. Laptop leaves the default (one reusable session box);
# CI overrides it per run (ci-<run_id>-<run_attempt>-<machine>) so parallel
# runs never collide on the name.
#YDEV_SESSION_NAME=ydev-session
```

- [ ] **Step 6: shellcheck + commit**

```bash
shellcheck -e SC1091 -e SC2039 scripts/ydev/remote-up.sh
git add scripts/ydev/remote-up.sh tests/ydev/test_remote_up.sh .env.example
git commit -m "feat(ydev): parameterise box name via YDEV_SESSION_NAME

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `--both`-Modus in `remote-build.sh` (prod+dev in einem kas-Lauf)

**Files:**
- Modify: `scripts/ydev/remote-build.sh`
- Modify: `tests/ydev/test_remote_build.sh`

**Interfaces:**
- Consumes: `remote-lib.sh` (`require_session`, `session_ip`, `ydev_ssh_args`, `ydev_rsh`).
- Produces: neuer Flag `--both` für `remote-build.sh`, der `--target oe5xrx-remotestation-image --target oe5xrx-remotestation-dev-image` an kas gibt. `--dev` (nur dev) und Default (nur prod) bleiben unverändert. `--both` und `--dev` schließen sich aus (letzter gewinnt nicht — Fehler).

- [ ] **Step 1: Failing test ergänzen**

In `tests/ydev/test_remote_build.sh` NACH dem `--dev`-Block einfügen:

```bash
# --both -> prod AND dev target in one kas invocation (CI dev_image=true path)
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh --both 2>&1)
echo "$out" | grep -q -- "kas build --target oe5xrx-remotestation-image --target oe5xrx-remotestation-dev-image qemux86-64.yml" \
  || { echo "FAIL both targets: $out"; exit 1; }
# --both with an explicit machine still works
out=$(YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh raspberrypi4-64 --both 2>&1)
echo "$out" | grep -q -- "kas build --target oe5xrx-remotestation-image --target oe5xrx-remotestation-dev-image raspberrypi4-64.yml" \
  || { echo "FAIL both targets rpi: $out"; exit 1; }
# --both and --dev are mutually exclusive
if YDEV_DRYRUN=1 bash scripts/ydev/remote-build.sh --both --dev 2>&1 | grep -q "mutually exclusive"; then :; else echo "FAIL both+dev guard"; exit 1; fi
```

Hinweis: Der bestehende `printf '1 1.2.3.4 t\n' > "$tmp/.ydev-session"`-Setup weiter oben in der Datei gilt auch hier (Session vorhanden).

- [ ] **Step 2: Test laufen lassen — muss FAILEN**

Run: `bash tests/ydev/test_remote_build.sh`
Expected: FAIL bei „both targets" (kein `--both` implementiert).

- [ ] **Step 3: `remote-build.sh` anpassen**

Arg-Parsing-Schleife erweitern:
```bash
machine="qemux86-64"; dev=0; both=0
for a in "$@"; do
  case "$a" in
    --both|both)                both=1 ;;
    --dev|dev)                  dev=1 ;;
    qemux86-64|raspberrypi4-64) machine="$a" ;;
    *) die_hint "unknown arg '$a'" "usage: just remote build [qemux86-64|raspberrypi4-64] [--dev|--both]" ;;
  esac
done
[ "$both" = 1 ] && [ "$dev" = 1 ] && die_hint "--both and --dev are mutually exclusive" "pick one"
```

Dryrun-Zeile ersetzen:
```bash
if [ "${YDEV_DRYRUN:-0}" = "1" ]; then
  if [ "$both" = 1 ]; then
    echo "DRYRUN: kas build --target oe5xrx-remotestation-image --target oe5xrx-remotestation-dev-image ${machine}.yml"
  else
    echo "DRYRUN: kas build$([ "$dev" = 1 ] && printf ' --target oe5xrx-remotestation-dev-image') ${machine}.yml"
  fi
fi
```

Heredoc-Aufruf: dritten Positional-Arg `both` übergeben und die Target-Wahl anpassen:
```bash
run ssh "${YDEV_SSH[@]}" "root@${ip}" bash -s -- "$machine" "$dev" "$both" <<'EOF'
  set -euo pipefail
  m="$1"; d="${2:-0}"; b="${3:-0}"; chown -R yocto:yocto /home/yocto/src
  # b=1 -> prod+dev in one invocation; d=1 -> dev only; else prod only.
  if [ "$b" = "1" ]; then
    tgt="--target oe5xrx-remotestation-image --target oe5xrx-remotestation-dev-image"
  elif [ "$d" = "1" ]; then
    tgt="--target oe5xrx-remotestation-dev-image"
  else
    tgt=""
  fi
  sudo -u yocto -H bash -lc "cd ~/src && export PATH=\$HOME/.local/bin:\$PATH && kas build ${tgt} ${m}.yml"
```
(Der R2-Publish-Teil im Heredoc bleibt unverändert.)

- [ ] **Step 4: Test laufen lassen — muss PASSEN**

Run: `bash tests/ydev/test_remote_build.sh`
Expected: `PASS test_remote_build`

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck -e SC1091 -e SC2039 scripts/ydev/remote-build.sh
git add scripts/ydev/remote-build.sh tests/ydev/test_remote_build.sh
git commit -m "feat(ydev): --both mode builds prod+dev in one kas run

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `OE5XRX_RELEASE_TAG` bis auf die Box weiterreichen (`remote-build.sh`)

**Files:**
- Modify: `scripts/ydev/remote-build.sh`
- Modify: `tests/ydev/test_remote_build.sh`

**Interfaces:**
- Consumes: Env-Var `OE5XRX_RELEASE_TAG` (String, optional). Auf dem Laptop unset → Box/kas nutzt den `oe5xrx.yml`-Default. In CI von `build.yml` gesetzt (`inputs.release_tag || 'dev'`).
- Produces: `remote-build.sh` exportiert `OE5XRX_RELEASE_TAG` in die kas-Umgebung des `yocto`-Users auf der Box, sodass BitBake das Stamp übernimmt (identisch zum alten `build.yml`-Verhalten).

- [ ] **Step 1: Failing test ergänzen**

In `tests/ydev/test_remote_build.sh` bei den Script-Content-Assertions ergänzen:

```bash
# release-tag passthrough into the box kas env (parity with old build.yml stamping)
grep -q "OE5XRX_RELEASE_TAG" scripts/ydev/remote-build.sh || { echo "FAIL release-tag passthrough missing"; exit 1; }
```

- [ ] **Step 2: Test laufen lassen — muss FAILEN**

Run: `bash tests/ydev/test_remote_build.sh`
Expected: FAIL „release-tag passthrough missing".

- [ ] **Step 3: `remote-build.sh` anpassen**

Vor dem ssh-Heredoc die Tag-Variable lokal auflösen und als viertes Positional-Arg übergeben:
```bash
rt="${OE5XRX_RELEASE_TAG:-}"
run ssh "${YDEV_SSH[@]}" "root@${ip}" bash -s -- "$machine" "$dev" "$both" "$rt" <<'EOF'
  set -euo pipefail
  m="$1"; d="${2:-0}"; b="${3:-0}"; rt="${4:-}"; chown -R yocto:yocto /home/yocto/src
  ...
  # Forward the release tag so BitBake stamps /etc/issue + os-release (oe5xrx.yml
  # lists OE5XRX_RELEASE_TAG in its env: block). Empty -> box default applies.
  sudo -u yocto -H bash -lc "cd ~/src && export PATH=\$HOME/.local/bin:\$PATH && export OE5XRX_RELEASE_TAG='${rt}' && kas build ${tgt} ${m}.yml"
```

- [ ] **Step 4: Test laufen lassen — muss PASSEN**

Run: `bash tests/ydev/test_remote_build.sh`
Expected: `PASS test_remote_build`

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck -e SC1091 -e SC2039 scripts/ydev/remote-build.sh
git add scripts/ydev/remote-build.sh tests/ydev/test_remote_build.sh
git commit -m "feat(ydev): forward OE5XRX_RELEASE_TAG into box kas env

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Prod-only-Artifact-Collector

**Files:**
- Create: `scripts/ydev/ci-collect-prod-artifacts.sh`
- Create: `tests/ydev/test_ci_collect_prod_artifacts.sh`

**Interfaces:**
- Consumes: `${YDEV_ROOT}/dist/<machine>/` (von `remote-download.sh` befüllt).
- Produces: `${YDEV_ROOT}/artifacts/` mit den Prod-Images (`*.ext4 *.wic *.wic.gz *.wic.bz2 *.wic.xz bzImage-* Image-* zImage-* *.qemuboot.conf *.dtb`), OHNE `oe5xrx-remotestation-dev-image-*` und OHNE `*.p7`. Aufruf: `ci-collect-prod-artifacts.sh <machine>`.

- [ ] **Step 1: Failing test schreiben**

Create `tests/ydev/test_ci_collect_prod_artifacts.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT; export YDEV_ROOT="$tmp"
d="$tmp/dist/qemux86-64"; mkdir -p "$d"
# prod + dev images side by side, plus a signature file that must be dropped
: > "$d/oe5xrx-remotestation-image-qemux86-64.wic.bz2"
: > "$d/bzImage-qemux86-64.bin"
: > "$d/oe5xrx-remotestation-image-qemux86-64.qemuboot.conf"
: > "$d/oe5xrx-remotestation-dev-image-qemux86-64.wic.bz2"
: > "$d/oe5xrx-remotestation-image-qemux86-64.wic.bz2.p7"
bash scripts/ydev/ci-collect-prod-artifacts.sh qemux86-64
a="$tmp/artifacts"
[ -f "$a/oe5xrx-remotestation-image-qemux86-64.wic.bz2" ] || { echo "FAIL prod wic missing"; exit 1; }
[ -f "$a/bzImage-qemux86-64.bin" ] || { echo "FAIL kernel missing"; exit 1; }
[ -f "$a/oe5xrx-remotestation-image-qemux86-64.qemuboot.conf" ] || { echo "FAIL qemuboot missing"; exit 1; }
[ -e "$a/oe5xrx-remotestation-dev-image-qemux86-64.wic.bz2" ] && { echo "FAIL dev image leaked into artifact"; exit 1; }
[ -e "$a/oe5xrx-remotestation-image-qemux86-64.wic.bz2.p7" ] && { echo "FAIL .p7 leaked into artifact"; exit 1; }
echo "PASS test_ci_collect_prod_artifacts"
```

- [ ] **Step 2: Test laufen lassen — muss FAILEN**

Run: `bash tests/ydev/test_ci_collect_prod_artifacts.sh`
Expected: FAIL (Skript existiert nicht → „No such file").

- [ ] **Step 3: Collector schreiben**

Create `scripts/ydev/ci-collect-prod-artifacts.sh`:
```bash
#!/usr/bin/env bash
# CI-only: collect PROD images from dist/<machine>/ into artifacts/, excluding
# the dev-image rootfs/wic (the artifact feeds boot-ota-test, which must boot
# the prod image). Mirrors the old build.yml "Collect artifacts" find set.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"; load_env
machine="${1:-qemux86-64}"
case "$machine" in qemux86-64|raspberrypi4-64) ;; *) die_hint "unknown machine '$machine'" "qemux86-64 | raspberrypi4-64";; esac
src="${YDEV_ROOT}/dist/${machine}"
[ -d "$src" ] || die_hint "no dist dir $src" "run remote-download.sh first"
out="${YDEV_ROOT}/artifacts"; mkdir -p "$out"
# -L: follow symlinks so we copy real files, not dangling links.
find -L "$src" \
  \( -name "*.ext4" -o -name "*.wic" -o -name "*.wic.gz" \
     -o -name "*.wic.bz2" -o -name "*.wic.xz" \
     -o -name "bzImage-*" -o -name "Image-*" -o -name "zImage-*" \
     -o -name "*.qemuboot.conf" -o -name "*.dtb" \) \
  -not -name "*.p7" \
  -not -name "oe5xrx-remotestation-dev-image-*" \
  | while read -r f; do cp -L "$f" "$out/"; done
echo "collected prod artifacts → $out/"
ls -lh "$out/" || true
```
`chmod +x scripts/ydev/ci-collect-prod-artifacts.sh`

- [ ] **Step 4: Test laufen lassen — muss PASSEN**

Run: `bash tests/ydev/test_ci_collect_prod_artifacts.sh`
Expected: `PASS test_ci_collect_prod_artifacts`

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck -e SC1091 -e SC2039 scripts/ydev/ci-collect-prod-artifacts.sh
git add scripts/ydev/ci-collect-prod-artifacts.sh tests/ydev/test_ci_collect_prod_artifacts.sh
git commit -m "feat(ydev): prod-only CI artifact collector (excludes dev-image)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: ydev-Tests + Lint in CI verdrahten (`ci.yml`)

**Files:**
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: alle `tests/ydev/*.sh`, alle `scripts/ydev/*.sh`.
- Produces: neuer Job `ydev-scripts` im CI, der die ydev-Skripte shellchecked und alle `tests/ydev/*.sh` fährt. Damit gaten die Tasks 1–4 auch in CI (heute laufen die ydev-Tests nirgends).

- [ ] **Step 1: Job ergänzen**

In `.github/workflows/ci.yml` als neuen Job unter `jobs:` (nach `sim-harness`) einfügen:
```yaml
  ydev-scripts:
    name: ydev scripts (lint + dry-run tests)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6
      - name: Install shellcheck
        run: sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends shellcheck
      - name: Shellcheck ydev scripts
        run: shellcheck -e SC1091 -e SC2039 scripts/ydev/*.sh scripts/ydev/box/ydev-watchdog.sh
      - name: Run ydev dry-run tests
        run: |
          set -euo pipefail
          for t in tests/ydev/test_*.sh; do
            echo "== $t =="
            bash "$t"
          done
```

- [ ] **Step 2: Lokal die Job-Schritte nachstellen — müssen PASSEN**

Run:
```bash
shellcheck -e SC1091 -e SC2039 scripts/ydev/*.sh scripts/ydev/box/ydev-watchdog.sh
for t in tests/ydev/test_*.sh; do echo "== $t =="; bash "$t"; done
```
Expected: shellcheck ohne Findings; jeder Test endet mit `PASS ...`.
(Falls ein bestehendes ydev-Skript pre-existing shellcheck-Findings hat, im Commit-Scope dieses Tasks minimal fixen ODER die betroffene Datei gezielt mit Inline-`# shellcheck disable=`-Kommentar versehen — NICHT die Regeln global lockern.)

- [ ] **Step 3: yamllint über den geänderten Workflow**

Run:
```bash
yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable, truthy: disable, comments-indentation: disable, indentation: {check-multi-line-strings: false}}}" .github/workflows/ci.yml
```
Expected: keine Fehler.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: lint + run ydev dry-run tests

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: `build.yml` zum GH-hosted Wrapper umbauen

**Files:**
- Rewrite: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: `remote-up.sh` (`YDEV_SESSION_NAME`, `YDEV_SERVER_TYPE`, `YDEV_IDLE_MINUTES`, `YDEV_MAX_HOURS`, `HCLOUD_TOKEN`, `HCLOUD_SSH_KEY_NAME`, `HCLOUD_SSH_KEY`, `BWS_ACCESS_TOKEN`, `BWS_SERVER_URL`), `remote-build.sh` (`--both`, `OE5XRX_RELEASE_TAG`), `remote-download.sh`, `ci-collect-prod-artifacts.sh`, `remote-down.sh`.
- Produces: unverändertes reusable Interface (Inputs `machine`/`release_tag`/`dev_image`; Artifact `yocto-image-<machine>`).

- [ ] **Step 1: `build.yml` komplett ersetzen**

Neuer Inhalt (Trigger-`paths` unverändert aus dem Bestand übernehmen):

```yaml
name: Build Yocto Image

# Full Yocto builds on an on-demand Hetzner box driven over SSH via the ydev
# scripts (scripts/ydev/remote-*). The box arms its own cloud-init teardown
# (idle + max-life + self-heal) at boot; the explicit remote-down.sh below is
# the happy-path teardown, the cloud-init net catches run cancellation.
on:
  workflow_dispatch:
    inputs:
      machine:
        description: "Target machine"
        type: choice
        options: [qemux86-64, raspberrypi4-64]
        default: qemux86-64
      release_tag:
        description: "Release tag for /etc/issue + /etc/os-release stamp (empty -> dev)"
        type: string
        default: ""
      dev_image:
        description: "Also build the dev-image target (fast-dev-loop) in the same invocation"
        type: boolean
        default: false
  workflow_call:
    inputs:
      machine:
        description: "Target machine"
        type: string
        required: true
      release_tag:
        description: "Release tag for /etc/issue + /etc/os-release stamp (empty -> dev)"
        type: string
        default: ""
      dev_image:
        description: "Also build the dev-image target (fast-dev-loop) in the same invocation"
        type: boolean
        default: false
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]
    paths:
      - 'oe5xrx.yml'
      - 'qemux86-64.yml'
      - 'raspberrypi4-64.yml'
      - '*.lock.yml'
      - 'meta-oe5xrx-remotestation/conf/**'
      - 'meta-oe5xrx-remotestation/recipes-kernel/**'
      - 'meta-oe5xrx-remotestation/recipes-core/base-files/**'
      - 'meta-oe5xrx-remotestation/recipes-core/oe5xrx-boot-robustness/**'
      - 'meta-oe5xrx-remotestation/recipes-core/oe5xrx-fm-firmware/**'
      - 'meta-oe5xrx-remotestation/recipes-core/oe5xrx-native-sim-fm/**'
      - 'meta-oe5xrx-remotestation/recipes-core/oe5xrx-sim-harness/**'
      - 'meta-oe5xrx-remotestation/recipes-core/oe5xrx-slot-udev/**'
      - 'meta-oe5xrx-remotestation/recipes-core/packagegroups/**'
      - '.github/workflows/build.yml'

permissions:
  contents: read
  actions: read

concurrency:
  group: yocto-build-${{ inputs.machine || 'qemux86-64' }}-${{ github.event_name == 'pull_request' && github.event.pull_request.number || 'release' }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

env:
  KAS_MACHINE: ${{ inputs.machine || 'qemux86-64' }}
  OE5XRX_RELEASE_TAG: ${{ inputs.release_tag || 'dev' }}
  # ydev CI config (shared-vCPU CPX; short idle + hard max-life self-teardown)
  YDEV_SERVER_TYPE: cpx62
  YDEV_LOCATION: fsn1
  YDEV_IDLE_MINUTES: "10"
  YDEV_MAX_HOURS: "3"

jobs:
  build:
    name: Build Yocto Image
    runs-on: ubuntu-latest
    # Skip draft PRs — don't spin an (expensive) box for WIP pushes. For
    # dispatch/workflow_call there is no pull_request, so this is true.
    if: ${{ !github.event.pull_request.draft }}
    # Above the box's own YDEV_MAX_HOURS (=3h) so the box self-teardown is the
    # inner cap for a wedged build; +buffer for provisioning + download.
    timeout-minutes: 210
    env:
      HCLOUD_TOKEN: ${{ secrets.HCLOUD_TOKEN }}
      HCLOUD_SSH_KEY_NAME: ${{ secrets.HCLOUD_SSH_KEY_NAME }}
      BWS_ACCESS_TOKEN: ${{ secrets.BWS_ACCESS_TOKEN }}
      BWS_SERVER_URL: ${{ secrets.BWS_SERVER_URL }}
      DEV_IMAGE: ${{ inputs.dev_image }}
      YDEV_SESSION_NAME: ci-${{ github.run_id }}-${{ github.run_attempt }}-${{ inputs.machine || 'qemux86-64' }}
    steps:
      - uses: actions/checkout@d23441a48e516b6c34aea4fa41551a30e30af803 # v6

      - name: Validate machine input
        env:
          MACHINE: ${{ inputs.machine || 'qemux86-64' }}
        run: |
          case "$MACHINE" in
            qemux86-64|raspberrypi4-64) ;;
            *) echo "::error::Unsupported machine '$MACHINE'. Must be qemux86-64 or raspberrypi4-64." >&2; exit 1 ;;
          esac

      - name: Install hcloud + bws
        run: |
          set -euo pipefail
          curl -fsSL "https://github.com/hetznercloud/cli/releases/download/v1.67.0/hcloud-linux-amd64.tar.gz" | tar xz
          sudo mv hcloud /usr/local/bin/
          VER=0.5.0
          SHA=b9296341549d9ba6922da6692b24c4d81d14dc3992597d5a777692aee73b10b2
          curl -fsSL -o /tmp/bws.zip "https://github.com/bitwarden/sdk-sm/releases/download/bws-v${VER}/bws-x86_64-unknown-linux-gnu-${VER}.zip"
          echo "${SHA}  /tmp/bws.zip" | sha256sum -c -
          sudo unzip -o /tmp/bws.zip -d /usr/local/bin

      - name: Setup SSH key
        env:
          SSH_PRIVATE_KEY: ${{ secrets.HCLOUD_SSH_PRIVATE_KEY }}
        run: |
          set -euo pipefail
          mkdir -p ~/.ssh
          echo "${SSH_PRIVATE_KEY}" > ~/.ssh/hetzner
          chmod 600 ~/.ssh/hetzner
          echo "HCLOUD_SSH_KEY=$HOME/.ssh/hetzner" >> "$GITHUB_ENV"

      - name: Provision on-demand build box
        run: bash scripts/ydev/remote-up.sh

      - name: Build with kas
        run: |
          set -euo pipefail
          if [ "${DEV_IMAGE}" = "true" ]; then
            bash scripts/ydev/remote-build.sh "${KAS_MACHINE}" --both
          else
            bash scripts/ydev/remote-build.sh "${KAS_MACHINE}"
          fi

      - name: Download images
        run: bash scripts/ydev/remote-download.sh "${KAS_MACHINE}"

      - name: Verify dev-image wic built
        if: ${{ inputs.dev_image }}
        run: |
          set -euo pipefail
          wic=$(find "dist/${KAS_MACHINE}" -name 'oe5xrx-remotestation-dev-image-*.wic*' -print -quit)
          [ -n "${wic}" ] || { echo "::error::dev-image target produced no .wic"; exit 1; }
          echo "dev-image wic built: ${wic} ($(du -h "${wic}" | cut -f1))"

      - name: Collect prod-only artifacts
        run: bash scripts/ydev/ci-collect-prod-artifacts.sh "${KAS_MACHINE}"

      - name: Upload artifacts
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7
        with:
          name: yocto-image-${{ env.KAS_MACHINE }}
          path: artifacts/
          retention-days: 7

      - name: Teardown build box
        if: always()
        run: bash scripts/ydev/remote-down.sh
```

- [ ] **Step 2: yamllint — muss PASSEN**

Run:
```bash
yamllint -d "{extends: default, rules: {line-length: disable, document-start: disable, truthy: disable, comments-indentation: disable, indentation: {check-multi-line-strings: false}}}" .github/workflows/build.yml
```
Expected: keine Fehler.

- [ ] **Step 3: Statische Konsistenz-Checks**

Run:
```bash
# reusable inputs unverändert vorhanden
grep -q 'machine:' .github/workflows/build.yml && grep -q 'release_tag:' .github/workflows/build.yml && grep -q 'dev_image:' .github/workflows/build.yml || { echo "FAIL inputs"; exit 1; }
# Artifact-Name-Kontrakt erhalten
grep -q 'name: yocto-image-\${{ env.KAS_MACHINE }}' .github/workflows/build.yml || { echo "FAIL artifact name"; exit 1; }
# kein self-hosted Runner / keine Runner-Registrierung mehr
grep -q 'runs-on: ubuntu-latest' .github/workflows/build.yml || { echo "FAIL runs-on"; exit 1; }
! grep -qiE 'registration-token|config\.sh|--ephemeral|oe5xrx-yocto-builder' .github/workflows/build.yml || { echo "FAIL runner remnants"; exit 1; }
# Teardown ist if: always()
grep -q 'Teardown build box' .github/workflows/build.yml || { echo "FAIL teardown step"; exit 1; }
echo "static checks OK"
```
Expected: `static checks OK`.

- [ ] **Step 4: Caller-Parität verifizieren (Read-only)**

Run:
```bash
grep -nE 'uses: ./.github/workflows/build.yml' .github/workflows/boot-ota-pr.yml .github/workflows/release.yml
grep -n 'dev_image: true' .github/workflows/boot-ota-pr.yml
```
Expected: `boot-ota-pr.yml` ruft build.yml mit `dev_image: true`; `release.yml` mit `build-x64`/`build-rpi` (nur `machine` + `release_tag`). KEINE Änderung an den Callern nötig — nur bestätigen.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "feat(ci): build.yml drives on-demand box via ydev scripts

Collapses create-runner/self-hosted-build/cleanup into one ubuntu-latest
job that provisions, builds, downloads and tears down the box over SSH.
Unique per-run box name + cloud-init self-teardown kill the PR55 orphan
and name-conflict classes. No GitHub runner registration anymore.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Live-E2E-Verifikation auf dem PR (kein Code)

Workflows lassen sich nicht unit-testen — die echte Prüfung ist ein Live-Run. Diese Checks nach dem Öffnen des PRs durchführen (Spec §7).

**Interfaces:** nutzt den echten CI-Lauf des PRs + `hcloud server list`.

- [ ] **Step 1: PR öffnen und einen x64-Build triggern**

PR gegen `main` öffnen (Branch `feat/ci-ydev-converge`). Da `.github/workflows/build.yml` in den `pull_request.paths` steht, feuert `build.yml` (qemux86-64). Alternativ manuell:
```bash
gh workflow run build.yml -f machine=qemux86-64 -f dev_image=true
```

- [ ] **Step 2: Erfolg + Teardown verifizieren**

```bash
gh run watch --exit-status   # Build grün?
hcloud server list -l managed-by==ydev   # muss die ci-<run_id>-... Box NICHT mehr zeigen
```
Expected: Build grün; keine übrige CI-Box.

- [ ] **Step 3: Artifact-Parität verifizieren**

Im Run-Log prüfen: „Collect prod-only artifacts" listet die Prod-`.wic*` + Kernel + qemuboot, **kein** `oe5xrx-remotestation-dev-image-*`. „Verify dev-image wic built" ist grün (dev wurde gebaut, aber nicht ins Artifact). Der nachgelagerte `boot-ota-test` (via `boot-ota-pr.yml`, falls boot-kritische Pfade berührt) bootet erfolgreich.

- [ ] **Step 4: Parallel-Test (Namenskonflikt-Freiheit)**

Zwei `build.yml`-Dispatches für qemux86-64 quasi-gleichzeitig starten:
```bash
gh workflow run build.yml -f machine=qemux86-64
gh workflow run build.yml -f machine=qemux86-64
hcloud server list -l managed-by==ydev   # zwei Boxen mit UNTERSCHIEDLICHEN ci-*-Namen
```
Expected: beide Runs provisionieren je eine eigene Box (verschiedene Namen), kein `server create`-Konflikt, beide danach weg.

- [ ] **Step 5: Notfall-Teardown (Cancellation)**

Einen Build starten, mitten im „Build with kas" **canceln** (`gh run cancel <id>`). Der „Teardown build box"-Step läuft dann nicht. Verifizieren, dass die Box via cloud-init verschwindet — spätestens nach `YDEV_MAX_HOURS` (3h), i.d.R. nach `YDEV_IDLE_MINUTES` (10 min) Idle:
```bash
# nach ~10-15 min bzw. via ScheduleWakeup erneut prüfen:
hcloud server list -l managed-by==ydev
```
Expected: die gecancelte Box ist von selbst verschwunden.

- [ ] **Step 6: Ergebnis dokumentieren**

Beobachtungen (Build-Zeit warm/kalt, Teardown-Timing, evtl. CPX-SKU-Anpassung) kurz im PR-Text festhalten. Falls `cpx51` nicht ausreicht/nicht verfügbar → `YDEV_SERVER_TYPE` im `env:`-Block von `build.yml` anpassen.

---

## Self-Review

**Spec-Coverage:**
- §4.1 Box-Name → Task 1. §4.2 Wrapper/Teardown/CPX/Defaults → Task 6 (+ Task 1 Name, Tasks 2/3 build). §4.3 Backstop (kein Cron; `remote clean` im CI weggelassen) → per Entscheid umgesetzt (kein `clean`-Step in Task 6). §4.4 Secrets/Env → Task 6. §4.5 Caller-Parität → Task 6 Step 4. §5 Parität: #1 Prod-only → Task 4; #2 dev_image beide Targets → Task 2 (+ Task 6 `--both`-Aufruf); #3 release_tag → Task 3; #4 Maschinen-Validierung → Task 6 Step 1; #5 dev-wic-Verify → Task 6; #6 R2-Publish → unverändert in `remote-build.sh` (nichts zu tun). §7 Testing → Task 7 (+ Task 5 wired die Dryrun-Tests). §9 Open Questions: OQ1 `clean` weggelassen, OQ2 Defaults gesetzt (cpx51/10/3), OQ3 `--both` gewählt, OQ4 `YDEV_SESSION_FILE` = YAGNI (nicht implementiert).
- Lücken: keine offen. `YDEV_SESSION_FILE` bewusst nicht implementiert (Entscheid OQ4).

**Placeholder-Scan:** keine TBD/TODO; jeder Code-Step hat konkreten Inhalt.

**Typ-/Namens-Konsistenz:** `YDEV_SESSION_NAME`, `--both`, `OE5XRX_RELEASE_TAG`, `ci-collect-prod-artifacts.sh`, Artifact `yocto-image-<machine>` durchgängig identisch über Tasks 1–7. Positional-Args in `remote-build.sh` konsistent: `machine dev both rt` (Tasks 2→3).

**YAGNI/DRY:** Skripte direkt aufgerufen (kein `just` im CI); R2-Publish nicht dupliziert (lebt in `remote-build.sh`); Collector spiegelt exakt das alte `build.yml`-Find-Set.
