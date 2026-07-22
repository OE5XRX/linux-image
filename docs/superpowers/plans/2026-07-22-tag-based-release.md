# Tag-based Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the linux-image release into two workflows so the images are signed under the tag ref (`cosign` identity `…/release.yml@refs/tags/<tag>`), which station-manager already expects — without touching station-manager.

**Architecture:** `tag-release.yml` (dispatch on main) validates + computes the version + pushes the tag, then dispatches `release.yml` against that tag ref via `gh workflow run --ref <tag>` (a documented `GITHUB_TOKEN` exception — no PAT). `release.yml` becomes `on: workflow_dispatch`, runs on the tag ref, validates the tag format, builds/gates (reusing `build.yml` + `boot-ota-test.yml`), signs under the tag, publishes, and deletes the tag on failure.

**Tech Stack:** GitHub Actions (reusable workflows + composite action), cosign keyless, `gh` CLI, bash.

## Global Constraints

- Design doc: `docs/superpowers/specs/2026-07-22-tag-based-release-design.md` (authoritative; job details there).
- Tag format regex (single source in `scripts/compute-release-version.sh`): `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}[a-z]?$`.
- No PAT / no GitHub App: chaining uses the `workflow_dispatch` `GITHUB_TOKEN` exception.
- Reusable workflows `./.github/workflows/build.yml`, `./.github/workflows/boot-ota-test.yml` and composite `./.github/actions/compute-version` stay unchanged — only callers/inputs change.
- Do NOT modify station-manager. Do NOT change the FW-RemoteStation verification (`bump-fw-release.sh --check`, `@refs/heads/main`).
- `validate-tag` and `preflight` in `release.yml` run as jobs **always**; only their steps are `if: ${{ !inputs.dry_run }}` — otherwise the `needs`-chain skips `build`/`gate` in dry_run mode.
- Verification tool: `actionlint` (static). The load-bearing runtime assumption (dispatch@tag ⇒ cosign SAN `@refs/tags/<tag>`) is proven only by the first real release run + station-manager import.

---

### Task 1: Rewrite `release.yml` as the tag-triggered build/sign/publish flow (Flow 2)

**Files:**
- Modify: `.github/workflows/release.yml` (change trigger to `workflow_dispatch`; add `validate-tag`; inline `resolve-slot-a`; wire build/gate off `github.ref_name`; sign under the tag; add `cleanup`).

**Interfaces:**
- Consumes: `./.github/workflows/build.yml` (input `release_tag`, machine); `./.github/workflows/boot-ota-test.yml` (inputs `expected_tag`, `last_release_tag`); artifacts `yocto-image-qemux86-64`, `yocto-image-raspberrypi4-64`.
- Produces: a `workflow_dispatch` workflow named `Release` with a boolean input `dry_run` (default `false`), runnable via `gh workflow run release.yml --ref <tag>`. Publishes a GitHub Release on the dispatched tag; deletes the tag on failure.

- [ ] **Step 1: Change the trigger + permissions.** Replace `on: workflow_dispatch { inputs: dry_run }` block is kept, but the workflow is now intended to be dispatched **against a tag ref**. Keep:
  ```yaml
  on:
    workflow_dispatch:
      inputs:
        dry_run:
          description: "Build + gate only; do not validate-tag/sign/tag-cleanup/publish"
          type: boolean
          default: false
  permissions:
    contents: write      # publish release + delete tag on failure
    id-token: write      # cosign keyless OIDC
    actions: read
  concurrency:
    group: release
    cancel-in-progress: false
  ```

- [ ] **Step 2: Add the `validate-tag` job (runs always; steps dry_run-gated).**
  ```yaml
  jobs:
    validate-tag:
      name: Validate tag format
      runs-on: ubuntu-latest
      steps:
        - name: Require a well-formed tag ref
          if: ${{ !inputs.dry_run }}
          env:
            REF: ${{ github.ref }}
            REF_NAME: ${{ github.ref_name }}
          run: |
            set -euo pipefail
            case "$REF" in
              refs/tags/*) : ;;
              *) echo "::error::release.yml (non-dry-run) must run on a tag ref, got '$REF'"; exit 1 ;;
            esac
            # Same TAG_RE as scripts/compute-release-version.sh — keep in sync.
            if ! printf '%s' "$REF_NAME" | grep -Eq '^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}[a-z]?$'; then
              echo "::error::tag '$REF_NAME' is not a valid release tag (YYYY.MM.DD-HH[a-z])"; exit 1
            fi
            echo "tag $REF_NAME OK"
  ```

- [ ] **Step 3: Keep `preflight` (needs validate-tag; runs always, steps dry_run-gated).** Reuse the existing preflight steps (SRCREV-not-AUTOREV + `Install cosign` + `bump-fw-release.sh --check`), each step prefixed with `if: ${{ !inputs.dry_run }}`, and add `needs: validate-tag`.

- [ ] **Step 4: Replace the `version` job with `resolve-slot-a`.** Version is now `github.ref_name`; only slot A must be resolved:
  ```yaml
    resolve-slot-a:
      name: Resolve slot A (previous release)
      needs: preflight
      runs-on: ubuntu-latest
      outputs:
        last_release: ${{ steps.last.outputs.tag }}
      steps:
        - name: Resolve previous release
          id: last
          env:
            REPO: ${{ github.repository }}
            GH_TOKEN: ${{ github.token }}
          run: |
            set -euo pipefail
            tag=$(gh release list -R "$REPO" -L 1 --exclude-drafts --exclude-pre-releases --json tagName -q '.[0].tagName' || true)
            echo "Previous release: ${tag:-<none>}"
            echo "tag=$tag" >> "$GITHUB_OUTPUT"
  ```

- [ ] **Step 5: Point build + gate at `github.ref_name`.**
  ```yaml
    build-x64:
      name: Build qemux86-64
      needs: [preflight, validate-tag]
      uses: ./.github/workflows/build.yml
      with:
        machine: qemux86-64
        release_tag: ${{ github.ref_name }}
    build-rpi:
      name: Build raspberrypi4-64
      needs: [preflight, validate-tag]
      uses: ./.github/workflows/build.yml
      with:
        machine: raspberrypi4-64
        release_tag: ${{ github.ref_name }}
    gate:
      name: Boot & OTA gate (x64)
      needs: [resolve-slot-a, build-x64]
      uses: ./.github/workflows/boot-ota-test.yml
      with:
        expected_tag: ${{ github.ref_name }}
        last_release_tag: ${{ needs.resolve-slot-a.outputs.last_release }}
  ```
  (Copy the exact `with:` keys from the current `release.yml` build/gate calls — match names verbatim.)

- [ ] **Step 6: Sign & publish under the tag (job-level `if: !dry_run`).** Keep the existing download-artifact + `cosign sign-blob` + `softprops/action-gh-release` steps. Change every `${{ needs.version.outputs.version }}` → `${{ github.ref_name }}`. Set:
  ```yaml
    sign-publish:
      name: Sign & Publish Release
      needs: [validate-tag, build-x64, build-rpi, gate]
      if: ${{ !inputs.dry_run }}
      runs-on: ubuntu-latest
      # ... existing steps, TAG env := ${{ github.ref_name }}, tag_name := ${{ github.ref_name }}
  ```

- [ ] **Step 7: Add the failure `cleanup` job (delete the tag).**
  ```yaml
    cleanup:
      name: Delete tag on failure
      needs: [validate-tag, preflight, resolve-slot-a, build-x64, build-rpi, gate, sign-publish]
      if: ${{ failure() && !inputs.dry_run && startsWith(github.ref, 'refs/tags/') }}
      runs-on: ubuntu-latest
      permissions:
        contents: write
      steps:
        - uses: actions/checkout@v6
        - name: Delete the release tag so a failed attempt leaves nothing behind
          env:
            REF_NAME: ${{ github.ref_name }}
          run: |
            set -euo pipefail
            echo "Deleting tag $REF_NAME after a failed release run"
            git push origin ":refs/tags/${REF_NAME}" || echo "tag already gone"
  ```

- [ ] **Step 8: Lint.**

Run: `actionlint .github/workflows/release.yml`
Expected: no errors. (If `actionlint` missing: `go install github.com/rhysd/actionlint/cmd/actionlint@latest` or download the release binary; or rely on CI.)

- [ ] **Step 9: Commit.**
```bash
git add .github/workflows/release.yml
git commit -m "feat(release): tag-triggered build/sign/publish (Flow 2) — sign under the tag ref"
```

---

### Task 2: Add `tag-release.yml` (Flow 1 — compute + tag + dispatch)

**Files:**
- Create: `.github/workflows/tag-release.yml`.

**Interfaces:**
- Consumes: `./.github/actions/compute-version` (composite; outputs the computed `version`); dispatches `release.yml` from Task 1 via `gh workflow run release.yml --ref <tag>`.
- Produces: the one-button entrypoint (`workflow_dispatch` on main) operators use to cut a release.

- [ ] **Step 1: Write the workflow.**
  ```yaml
  name: Tag release
  # One-button entrypoint: compute the next version, create+push the tag, then
  # dispatch release.yml AGAINST that tag ref. GITHUB_TOKEN-pushed tags do not
  # trigger on:push (recursion guard), but workflow_dispatch IS a documented
  # GITHUB_TOKEN exception — so we dispatch explicitly instead of relying on push.
  on:
    workflow_dispatch: {}
  permissions:
    contents: write   # push the tag
    actions: write    # dispatch release.yml
  concurrency:
    group: tag-release
    cancel-in-progress: false
  jobs:
    preflight:
      name: Preflight — require pinned SRCREV
      runs-on: ubuntu-latest
      steps:
        # Copy the two preflight steps verbatim from release.yml's original
        # preflight job: (1) "Fail if station-agent SRCREV is AUTOREV",
        # (2) Install cosign + "Fail if FM artifacts are unpinned or unsigned"
        # (scripts/bump-fw-release.sh --check).
        - uses: actions/checkout@v6
        # ... (verbatim preflight steps) ...
    tag:
      name: Compute version + push tag
      needs: preflight
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@v6
          with:
            fetch-depth: 0    # full tag history for the collision suffix
        - name: Guard — real releases only on the default branch
          env:
            REF: ${{ github.ref_name }}
            DEFAULT: ${{ github.event.repository.default_branch }}
          run: |
            set -euo pipefail
            [ "$REF" = "$DEFAULT" ] || { echo "::error::tag-release must run on the default branch ($DEFAULT), got '$REF'"; exit 1; }
        - name: Compute next version
          id: cv
          uses: ./.github/actions/compute-version
        - name: Create + push the tag
          env:
            TAG: ${{ steps.cv.outputs.version }}
          run: |
            set -euo pipefail
            git config user.name  "github-actions[bot]"
            git config user.email "github-actions[bot]@users.noreply.github.com"
            git tag -a "$TAG" -m "Release $TAG"
            git push origin "refs/tags/${TAG}"
        - name: Dispatch release.yml against the tag
          env:
            TAG: ${{ steps.cv.outputs.version }}
            GH_TOKEN: ${{ github.token }}
          run: |
            set -euo pipefail
            gh workflow run release.yml --ref "$TAG" -f dry_run=false
            echo "Dispatched release.yml @ $TAG"
  ```
  Confirm the `compute-version` output name (`version`) by reading `.github/actions/compute-version/action.yml`; match it exactly.

- [ ] **Step 2: Lint.**

Run: `actionlint .github/workflows/tag-release.yml`
Expected: no errors.

- [ ] **Step 3: Commit.**
```bash
git add .github/workflows/tag-release.yml
git commit -m "feat(release): add tag-release.yml (Flow 1) — compute version, push tag, dispatch release.yml"
```

---

### Task 3: Docs + PR

**Files:**
- Modify: any release-process doc that describes "one-button `release.yml` dispatch" (search `docs/` for `workflow_dispatch`/`release.yml`); update to the two-step tag flow + retry semantics (retry = re-dispatch `tag-release.yml`, not re-run `release.yml`).

- [ ] **Step 1: Grep for release-process docs.**

Run: `grep -rniE 'release\.yml|one-button|workflow_dispatch' docs/ README* 2>/dev/null | grep -v superpowers/`
Update prose that describes the old single-workflow flow.

- [ ] **Step 2: Commit + open PR.**
```bash
git add -A
git commit -m "docs(release): document the two-step tag-based release flow"
gh pr create --base main --title "feat(release): tag-based release (two workflows, tag-scoped cosign identity)" --body "<summary + Closes/refs the station-manager cosign-mismatch>"
```

- [ ] **Step 3: Acceptance (real run, after merge).** Cut a release via `tag-release.yml`; confirm: (a) tag created, (b) `release.yml` ran on the tag, (c) published release's `cosign` cert SAN is `…/release.yml@refs/tags/<tag>`, (d) station-manager imports it (`cosign verify-blob` green) and it can be queued/deployed. If a build/gate fails, confirm the tag was deleted by `cleanup`.

## Self-Review

- **Spec coverage:** Flow 1 → Task 2; Flow 2 (validate-tag, preflight, resolve-slot-a, build/gate, sign-publish, cleanup, dry_run needs-chain) → Task 1; docs/retry → Task 3; acceptance/load-bearing-assumption → Task 3 Step 3. FW-verification + station-manager untouched = global constraints. Covered.
- **Placeholders:** the "copy verbatim from current release.yml" notes point to concrete existing steps (preflight, sign-publish) rather than re-pasting 40 lines twice; the implementer has the file open. Acceptable (not a vague TODO).
- **Type/name consistency:** `github.ref_name` used for tag/version throughout; `resolve-slot-a.outputs.last_release` matches the gate input `last_release_tag`; `compute-version` output `version` (verify in action.yml before use).
