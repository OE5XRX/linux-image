# Contributing to OE5XRX Linux image

Patches welcome. Submit via pull request against `main`.

## Quick start

```bash
# Fork on GitHub, then:
git clone git@github.com:<you>/linux-image.git
cd linux-image
git checkout -b fix/my-thing

# Make your change...
git commit -m "Short subject; why, not what."
git push origin fix/my-thing

# Open a PR against OE5XRX/linux-image main.
```

## Rules

1. **Every change goes through a PR.** Direct pushes to `main` are
   blocked. Reviewers check that CI is green before merging.
2. **Keep PRs focused.** One logical change per PR. Rebase to squash
   fixups — the merge will be a single commit either way (linear
   history is enforced).
3. **CI must be green.** The [`ci.yml`](.github/workflows/ci.yml)
   workflow runs on every PR and validates that kas configs parse,
   shell scripts pass `shellcheck`, YAML passes `yamllint`, and the
   partition layouts (`.wks.in`) are well-formed.
4. **Don't commit build output.** `.gitignore` covers `build/`,
   `sstate-cache/`, `downloads/` — never force-add those.
5. **Touch as few unrelated files as possible.** If your fix needs a
   refactor, do the refactor in a separate PR first.
6. **Commit messages** — one-line subject (imperative, ≤72 chars),
   blank line, body explaining the *why*. Example:
   ```
   ab-layout: guard data-init against missing /mnt/data

   On first boot before the overlayfs mount is ready, data-init
   would try to create subdirs in a rootfs-read-only /mnt/data
   and fail. Fail gracefully with a log message instead.
   ```

## What good contributions look like

- A failing scenario reproduced in QEMU, then a fix, then a note in
  the PR description showing the QEMU output before and after.
- Yocto recipe changes with a clean `kas build` on at least one
  target. Paste the tail of the build log in the PR.
- Shell or Python scripts that pass `shellcheck` / `ruff`.

## Testing locally

```bash
# Validate kas configs (same checks as CI)
kas dump qemux86-64.yml > /dev/null
kas dump raspberrypi4-64.yml > /dev/null

# Lint
shellcheck meta-oe5xrx-remotestation/recipes-core/ab-layout/files/*.sh
yamllint *.yml .github/workflows/

# Full build (slow — use the Hetzner CI for a clean check)
kas build qemux86-64.yml

# Boot it
./scripts/run-qemu.sh
```

## DCO / sign-off

Sign off commits (`git commit -s`) if you want to certify you have the
right to submit the change under the repo's license (GPL-3.0-or-later).
We don't enforce it mechanically but it's appreciated.

## License

By submitting a pull request, you agree that your contribution is
licensed under **GPL-3.0-or-later**, same as the rest of the repo.
