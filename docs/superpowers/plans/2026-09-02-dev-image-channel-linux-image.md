# Dev-Image Channel — linux-image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Das dev-Image wird als signiertes Release-Asset für beide Machines publiziert, symmetrisch benannt (`oe5xrx-<machine>-<channel>-<tag>.wic.bz2`), und beide Images tragen den gebackenen Marker `VARIANT_ID` in `/etc/os-release`.

**Architecture:** Die bestehende `stamp_release()`-Postprocess-Funktion schreibt zusätzlich `VARIANT_ID`, gesteuert durch die neue BitBake-Variable `OE5XRX_IMAGE_VARIANT` (prod default `release`, dev override `dev`). `release.yml` baut via `dev_image: true` beide Targets; ein neues `ci-collect-dev-artifacts.sh` sammelt das dev-wic in ein separates Build-Artefakt; der Package/Sign-Step benennt und signiert **beide** Channels symmetrisch mit der unveränderten cosign-Chain.

**Tech Stack:** Yocto/OE (kas), BitBake Python-Postprocess, GitHub Actions, cosign keyless, bash (shellcheck/yamllint guards).

**Spec:** `../station-manager/docs/superpowers/specs/2026-09-02-dev-image-channel-design.md` (Repo `OE5XRX/station-manager`; Teil A)

## Global Constraints

- Asset-Naming symmetrisch: `oe5xrx-<machine>-<channel>-<tag>.wic.bz2` (+`.sha256`, +`.bundle`), auch für `release`. Breaking-Change ggü. `oe5xrx-<machine>-<tag>.wic.bz2`.
- **`release.yml` NICHT umbenennen** — cosign leitet die keyless-Identität aus dem Workflow-Pfad ab. cosign-Aufruf-Struktur (`sign-blob --bundle`) und Identität (`release.yml@refs/tags/<tag>`) bleiben unverändert.
- Machines: `qemux86-64` und `raspberrypi4-64` (unverändert, echte Yocto-MACHINE).
- `VARIANT_ID`-Wert == `<channel>`-Token im Dateinamen (gebackene Wahrheit ↔ Name).
- `l0-dev-packages-lint.sh` (one-way dev/prod-Split) bleibt unangetastet.
- Der Boot-/OTA-Gate-Job bootet weiterhin das **prod**-Artefakt (`yocto-image-<machine>`).

---

### Task 1: `VARIANT_ID` in beide Images backen

**Files:**
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb` (bei `OE5XRX_RELEASE_TAG`, ~Zeile 125; und `stamp_release()` overrides, ~Zeile 165)
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-dev-image.bb` (nach dem `require`)
- Create: `scripts/l1-image-variant-lint.sh` (static guard)
- Modify: `.github/workflows/ci.yml` (guard einhängen, neben der `dev-isolation`-Job-Definition)

**Interfaces:**
- Produces: `/etc/os-release` enthält `VARIANT_ID="release"` (prod) bzw. `VARIANT_ID="dev"` (dev).

- [ ] **Step 1: Add the BitBake variable + override**

In `oe5xrx-remotestation-image.bb`, direkt unter `OE5XRX_RELEASE_TAG ??= "dev"` (Zeile ~125):

```bitbake
# Baked image variant/channel (release, dev, …). Weak default so the dev
# image can override it after `require`. Written into /etc/os-release as
# VARIANT_ID by stamp_release() below; the release asset name mirrors it.
OE5XRX_IMAGE_VARIANT ??= "release"
```

In `oe5xrx-remotestation-dev-image.bb`, direkt nach `require oe5xrx-remotestation-image.bb`:

```bitbake
# This is the development variant — overrides the prod default so the baked
# VARIANT_ID marker is unfalsifiable at build time.
OE5XRX_IMAGE_VARIANT = "dev"
```

- [ ] **Step 2: Extend `stamp_release()` to write VARIANT_ID**

In `stamp_release()`, den `overrides`-Dict (Zeile ~160) erweitern:

```python
    variant = d.getVar('OE5XRX_IMAGE_VARIANT') or 'release'
    if not re.fullmatch(r'[a-z0-9-]+', variant):
        bb.fatal(
            f"OE5XRX_IMAGE_VARIANT={variant!r} must be a lowercase slug "
            "[a-z0-9-]; it becomes VARIANT_ID and the release asset token."
        )

    overrides = {
        'PRETTY_NAME': f'OE5XRX Remote Station {tag}',
        'VERSION': tag,
        'VERSION_ID': tag,
        'OE5XRX_RELEASE': tag,
        'VARIANT': 'Development' if variant == 'dev' else 'Release',
        'VARIANT_ID': variant,
    }
```

(The existing in-place rewrite loop already handles both replacing an existing `VARIANT_ID=`/`VARIANT=` line and appending it once — no further change needed.)

- [ ] **Step 3: Write the static guard**

```bash
#!/usr/bin/env bash
# CI: assert the image-variant marker wiring stays intact.
#  - prod image declares a weak-default OE5XRX_IMAGE_VARIANT
#  - dev image overrides it to "dev"
#  - stamp_release writes VARIANT_ID
set -euo pipefail
IMG_DIR="meta-oe5xrx-remotestation/recipes-core/images"
PROD="${IMG_DIR}/oe5xrx-remotestation-image.bb"
DEV="${IMG_DIR}/oe5xrx-remotestation-dev-image.bb"
fail=0

grep -Eq '^\s*OE5XRX_IMAGE_VARIANT\s*\?\?=\s*"release"' "${PROD}" || {
  echo "::error file=${PROD}::prod image must weak-default OE5XRX_IMAGE_VARIANT to \"release\""; fail=1; }

grep -Eq '^\s*OE5XRX_IMAGE_VARIANT\s*=\s*"dev"' "${DEV}" || {
  echo "::error file=${DEV}::dev image must set OE5XRX_IMAGE_VARIANT = \"dev\""; fail=1; }

grep -q "'VARIANT_ID': variant" "${PROD}" || {
  echo "::error file=${PROD}::stamp_release must write VARIANT_ID"; fail=1; }

exit "${fail}"
```

- [ ] **Step 4: Run the guard locally to verify it passes**

Run: `bash scripts/l1-image-variant-lint.sh && echo OK`
Expected: `OK` (exit 0).

- [ ] **Step 5: Negative check — guard catches a regression**

Run:
```bash
sed 's/OE5XRX_IMAGE_VARIANT = "dev"/OE5XRX_IMAGE_VARIANT = "release"/' \
  meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-dev-image.bb \
  > /tmp/dev.bb && cp /tmp/dev.bb /tmp/dev-broken.bb
# temporarily point the guard at the broken copy to prove it fails
```
Simpler: manually confirm by reading the guard that removing the dev override makes `grep` fail → `exit 1`. Then ensure the real file is intact (`bash scripts/l1-image-variant-lint.sh` → OK).

- [ ] **Step 6: Wire the guard into CI**

In `.github/workflows/ci.yml`, neben dem bestehenden `dev-isolation`-Job einen Step ergänzen (gleicher Job oder neuer Job mit `runs-on: ubuntu-latest`, `checkout`, dann):

```yaml
      - name: Image-variant marker lint
        run: bash scripts/l1-image-variant-lint.sh
```

- [ ] **Step 7: Lint the new script**

Run: `shellcheck scripts/l1-image-variant-lint.sh`
Expected: no findings.

- [ ] **Step 8: Commit**

```bash
git add meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb \
        meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-dev-image.bb \
        scripts/l1-image-variant-lint.sh .github/workflows/ci.yml
git commit -m "feat(image): bake VARIANT_ID marker into release and dev images"
```

---

### Task 2: `ci-collect-dev-artifacts.sh` — dev-wic einsammeln

**Files:**
- Create: `scripts/ydev/ci-collect-dev-artifacts.sh`
- Test: (dry-run against a fixture dist dir — mirrors existing ydev script dry-run tests in `ci.yml`)

**Interfaces:**
- Consumes: `dist/<machine>/` (contains `oe5xrx-remotestation-dev-image-*.wic.bz2` after a `--both` build).
- Produces: `artifacts-dev/` containing only the dev wic (+ sha sidecars if present).

- [ ] **Step 1: Write the collector (mirror of the prod collector, inverted filter)**

```bash
#!/usr/bin/env bash
# CI-only: collect the DEV image wic from dist/<machine>/ into artifacts-dev/.
# Counterpart to ci-collect-prod-artifacts.sh — that one EXCLUDES the dev
# image; this one includes ONLY it, so release.yml can package both channels.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib.sh"; load_env
machine="${1:-qemux86-64}"
case "$machine" in qemux86-64|raspberrypi4-64) ;; *) die_hint "unknown machine '$machine'" "qemux86-64 | raspberrypi4-64";; esac
src="${YDEV_ROOT}/dist/${machine}"
[ -d "$src" ] || die_hint "no dist dir $src" "run remote-download.sh first"
out="${YDEV_ROOT}/artifacts-dev"; mkdir -p "$out"
find -L "$src" \
  \( -name "oe5xrx-remotestation-dev-image-*.wic" \
     -o -name "oe5xrx-remotestation-dev-image-*.wic.gz" \
     -o -name "oe5xrx-remotestation-dev-image-*.wic.bz2" \
     -o -name "oe5xrx-remotestation-dev-image-*.wic.xz" \) \
  -not -name "*.p7" \
  | while read -r f; do cp -L "$f" "$out/"; done
echo "collected dev artifacts → $out/"
ls -lh "$out/" || true
```

- [ ] **Step 2: shellcheck**

Run: `shellcheck scripts/ydev/ci-collect-dev-artifacts.sh`
Expected: no findings.

- [ ] **Step 3: Dry-run against a fixture**

Run:
```bash
export YDEV_ROOT=$(mktemp -d)
mkdir -p "$YDEV_ROOT/dist/qemux86-64"
touch "$YDEV_ROOT/dist/qemux86-64/oe5xrx-remotestation-dev-image-qemux86-64.wic.bz2"
touch "$YDEV_ROOT/dist/qemux86-64/oe5xrx-remotestation-image-qemux86-64.wic.bz2"
bash scripts/ydev/ci-collect-dev-artifacts.sh qemux86-64
ls "$YDEV_ROOT/artifacts-dev"
```
Expected: `artifacts-dev/` contains ONLY the `dev-image` wic; the prod wic is absent.

> If `lib.sh`'s `load_env` requires vars beyond `YDEV_ROOT`, set them as the existing ydev dry-run tests in `ci.yml` do (read that job first).

- [ ] **Step 4: Commit**

```bash
git add scripts/ydev/ci-collect-dev-artifacts.sh
git commit -m "feat(ci): collect dev-image wic into a separate artifact"
```

---

### Task 3: `_build.yml` — dev-Artefakt hochladen

**Files:**
- Modify: `.github/workflows/_build.yml:132-140` (nach dem prod-collect/upload)

**Interfaces:**
- Consumes: `inputs.dev_image` (existiert bereits), `ci-collect-dev-artifacts.sh` (Task 2).
- Produces: Artifact `yocto-image-<machine>-dev` (nur wenn `dev_image`).

- [ ] **Step 1: Add collect + upload steps** nach dem `Upload artifacts`-Step (Zeile 140):

```yaml
      - name: Collect dev artifacts
        if: ${{ inputs.dev_image }}
        run: bash scripts/ydev/ci-collect-dev-artifacts.sh "${KAS_MACHINE}"

      - name: Upload dev artifacts
        if: ${{ inputs.dev_image }}
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7
        with:
          name: yocto-image-${{ env.KAS_MACHINE }}-dev
          path: artifacts-dev/
          retention-days: 7
```

(Place these BEFORE the `Teardown build box` step so the box is still up is not required — collect runs on the runner from the downloaded `dist/`, and teardown is `if: always()`. Put them right after `Upload artifacts`.)

- [ ] **Step 2: yamllint**

Run: `yamllint .github/workflows/_build.yml`
Expected: no errors (warnings per existing config tolerated).

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/_build.yml
git commit -m "feat(ci): upload dev-image as a separate build artifact"
```

---

### Task 4: `release.yml` — beide Channels bauen, benennen, signieren

**Files:**
- Modify: `.github/workflows/release.yml:114-131` (build jobs), `:160-205` (download + package/sign)

**Interfaces:**
- Consumes: `yocto-image-<machine>` (prod), `yocto-image-<machine>-dev` (dev, Task 3).
- Produces: Release assets `oe5xrx-<machine>-<channel>-<tag>.<ext>` (+`.sha256` +`.bundle`) for channel ∈ {release, dev}.

- [ ] **Step 1: Build dev in the release build jobs**

`build-x64` (Zeile 118-120) und `build-rpi` (Zeile 128-130): je `dev_image: true` ergänzen:

```yaml
    with:
      machine: qemux86-64
      release_tag: ${{ needs.validate-tag.outputs.release_tag }}
      dev_image: true
```
(analog für `raspberrypi4-64`.)

- [ ] **Step 2: Download the dev artifacts** in the `release` job (nach den zwei bestehenden Download-Steps, Zeile 170):

```yaml
      - name: Download x86-64 dev artifact
        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8
        with:
          name: yocto-image-qemux86-64-dev
          path: staging-dev/qemux86-64

      - name: Download Raspberry Pi dev artifact
        uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8
        with:
          name: yocto-image-raspberrypi4-64-dev
          path: staging-dev/raspberrypi4-64
```

- [ ] **Step 3: Rewrite the package/sign loop over machine × channel** (ersetzt Zeile 178-204):

```bash
          set -euo pipefail
          mkdir -p release

          pick_wic() {  # $1 = staging dir; echoes "src ext" or empty
            local dir="$1" ext match
            for ext in wic.bz2 wic.xz wic.gz wic; do
              match=$(ls "${dir}"/*.${ext} 2>/dev/null | head -1 || true)
              if [ -n "${match}" ]; then echo "${match} ${ext}"; return 0; fi
            done
            return 1
          }

          for machine in qemux86-64 raspberrypi4-64; do
            # release channel ← prod staging ; dev channel ← dev staging
            for pair in "release:staging/${machine}" "dev:staging-dev/${machine}"; do
              channel="${pair%%:*}"
              dir="${pair##*:}"
              read -r src srcext < <(pick_wic "${dir}" || true)
              if [ -z "${src:-}" ]; then
                echo "No ${channel} image artifact for ${machine}" >&2
                exit 1
              fi
              dest="release/oe5xrx-${machine}-${channel}-${TAG}.${srcext}"
              cp "${src}" "${dest}"
              (cd release && sha256sum "$(basename "${dest}")" > "$(basename "${dest}").sha256")
              cosign sign-blob --yes --bundle "${dest}.bundle" "${dest}"
            done
          done
          ls -lh release/
```

- [ ] **Step 4: Update the release-notes asset table** (Zeile 225-228):

```markdown
            | Target | Release | Dev |
            |---|---|---|
            | Raspberry Pi CM4 | `oe5xrx-raspberrypi4-64-release-${{ env.TAG }}.wic.bz2` | `oe5xrx-raspberrypi4-64-dev-${{ env.TAG }}.wic.bz2` |
            | QEMU x86-64 | `oe5xrx-qemux86-64-release-${{ env.TAG }}.wic.bz2` | `oe5xrx-qemux86-64-dev-${{ env.TAG }}.wic.bz2` |
```

- [ ] **Step 5: yamllint + shellcheck the embedded script**

Run: `yamllint .github/workflows/release.yml`
Expected: no errors.
Extract the `run:` block and shellcheck it if the repo has a helper for that (see how `ci.yml`'s workflow-shell lint works); otherwise eyeball against `set -euo pipefail`.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release.yml
git commit -m "feat(release): publish signed dev + release assets with symmetric channel naming"
```

---

### Task 5: SECURITY/Doku-Referenzen auf symmetrisches Naming

**Files:**
- Modify: `SECURITY.md` (Verifikations-Beispiele mit Asset-Namen — grep for `oe5xrx-` filenames)
- Modify: any `docs/` page referencing the old `oe5xrx-<machine>-<tag>.wic.bz2` naming (grep)

**Interfaces:** none (docs).

- [ ] **Step 1: Find stale asset-name references**

Run: `grep -rIn 'oe5xrx-[a-z0-9-]*-\${' SECURITY.md docs/ 2>/dev/null; grep -rIn 'oe5xrx-.*\.wic\.bz2' SECURITY.md docs/ README.md 2>/dev/null`
Expected: a list of doc lines using the old (channel-less) name.

- [ ] **Step 2: Update each to the symmetric name** (`oe5xrx-<machine>-release-<tag>.wic.bz2` for the prod/verification example; add a dev example where it clarifies).

- [ ] **Step 3: Commit**

```bash
git add SECURITY.md docs README.md
git commit -m "docs: update asset naming to symmetric channel scheme"
```

---

### Task 6: Verifikation (Release-Dry-Run / erste echte Release)

**Files:** none.

- [ ] **Step 1: Run the existing CI on the branch** — `ci.yml` guards (incl. new `l1-image-variant-lint.sh`, `l0-dev-packages-lint.sh`, yamllint, shellcheck, ydev dry-runs) must pass.

- [ ] **Step 2: Dry-run the release workflow if supported** (`release.yml` has an `inputs.dry_run` path — Zeile 151). Trigger with `dry_run: true` and confirm: both channels build, both `dev_image` build steps run, the `Verify dev-image wic built` step passes on both machines. (No publish on dry-run.)

- [ ] **Step 3: First real tagged release** (when the user cuts one): confirm the GitHub Release lists all 12 assets — for each machine: `release` + `dev`, each `.wic.bz2` + `.sha256` + `.bundle` — and that `cosign verify-blob` succeeds against the same identity regexp as before.

- [ ] **Step 4: Cross-check the baked marker** — boot (or guestfish-inspect) one dev wic and confirm `/etc/os-release` contains `VARIANT_ID="dev"`; a release wic contains `VARIANT_ID="release"`.

- [ ] **Step 5: Push and open the PR** (only when the user asks).

PR body: link Issue #118 and the station-manager PR; note that after both merge, `scripts/pin-station-agent.sh` should be bumped so the agent's `image_variant` heartbeat lands in the image.

---

## Self-Review

**Spec coverage (Teil A):**
- A1 VARIANT_ID backen → Task 1. ✓
- A2 dev publizieren (build both, collect, name symmetric, sign same chain) → Tasks 2, 3, 4. ✓
- A2 Guards (`l0` unangetastet, neuer `l1`-Marker-Guard) → Task 1. ✓
- A3 Agent-Pin-Bump → Follow-up, in Task 6 Step 5 als PR-Note verankert (kein Code hier). ✓
- Doku-Konsistenz → Task 5. ✓

**Placeholder scan:** Task 2 Step 3 and Task 5 Step 1 flag "read the existing ydev dry-run job / grep for names" — real project lookups, not placeholders. No TBDs.

**Consistency:** channel token order `oe5xrx-<machine>-<channel>-<tag>` is identical in Task 1 (marker mirrors name), Task 4 (packaging), Task 5 (docs), and matches the station-manager plan's `github.py`/`channels_for` prefix/suffix logic.
