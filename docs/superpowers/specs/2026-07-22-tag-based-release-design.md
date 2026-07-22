# Tag-based release (two workflows, tag-scoped cosign identity)

**Datum:** 2026-07-22
**Repo:** linux-image

## Problem

Der aktuelle `release.yml` ist ein einzelner `workflow_dispatch` auf **main**: er baut, gated, signiert und erzeugt den Tag erst ganz am Ende. Weil `cosign sign-blob` dabei auf dem main-Ref läuft, ist die keyless-Identity `…/release.yml@refs/heads/main`.

station-manager (`apps/images/cosign.py`) verifiziert Images gegen `…/release.yml@refs/tags/<tag>` — die Identity, die linux-image **früher** (tag-getriggert) produzierte. Seit dem Umbau auf dispatch-from-main passt das nicht mehr → jeder Image-Import scheitert an `cosign verify-blob` → `ImageImportJob` FAILED → Queue-Button springt zurück.

**Entscheidung:** Nicht den Verifier anpassen, sondern die Ursache — linux-image soll wieder **unter dem Tag** signieren. station-manager bleibt unangetastet.

## Zielbild

Zwei Workflows. Der Tag wird von einem Dispatch-Flow erzeugt; ein zweiter, **gegen den Tag-Ref dispatchter** Flow baut/gated/signiert/published → cosign-Identity `…/release.yml@refs/tags/<tag>`.

Kein PAT/keine App nötig: `GITHUB_TOKEN`-gepushte Tags triggern zwar **kein** `on: push` (Rekursionsschutz, per Design, nicht per Permission umgehbar), aber `workflow_dispatch` ist die dokumentierte Ausnahme, die `GITHUB_TOKEN` auslösen darf:

> „events triggered by the GITHUB_TOKEN will not create a new workflow run, with the following exceptions: `workflow_dispatch` and `repository_dispatch` events always create workflow runs." — GitHub Docs

## Komponenten

### Flow 1 — `.github/workflows/tag-release.yml` (`workflow_dispatch`, main)
Zweck: validieren, Version berechnen, **Tag erzeugen**, Flow 2 anstoßen. Kein Build.

Jobs:
1. **preflight** — identisch zum heutigen preflight (SRCREV nicht AUTOREV; `bump-fw-release.sh --check` für die FW-Assets). Fail fast **vor** dem Taggen.
2. **tag** (`needs: preflight`):
   - `actions/checkout@v6` mit `fetch-depth: 0` (Tag-Historie für die Kollisions-Berechnung).
   - Guard: nur auf dem Default-Branch (heutiger „real releases only on the default branch"-Guard).
   - Version via `./.github/actions/compute-version` (validiert bereits gegen `TAG_RE`).
   - Tag auf den aktuellen main-Commit erzeugen + pushen (`GITHUB_TOKEN`, `permissions: contents: write`).
   - Flow 2 starten: `gh workflow run release.yml --ref "$TAG"` (`GITHUB_TOKEN`, erlaubte Ausnahme).

`permissions`: `contents: write` (Tag pushen), `actions: write` (workflow_dispatch auslösen).

### Flow 2 — `.github/workflows/release.yml` (`on: workflow_dispatch`, läuft auf dem Tag-Ref)
`workflow_dispatch`-Inputs: `dry_run` (bool, default false).

**Wichtig — dry_run & `needs`-Kette:** GitHub überspringt Jobs, deren `needs`-Vorgänger *übersprungen* wurden. Würde man `validate-tag` per Job-`if: !dry_run` skippen, würden auch `build`/`gate` (die davon abhängen) übersprungen → dry_run kaputt. Deshalb: **`validate-tag` läuft als Job immer** — nur sein Tag-Format-Check-*Step* ist `if: ${{ !inputs.dry_run }}`-gated (im dry_run ein No-op-`success`); derselbe Job löst zusätzlich den `release_tag`-Output auf. **`preflight` läuft ebenfalls immer** (unconditionally, die Reusable nimmt kein `dry_run`-Input — der Preflight ist billig und validiert den Zustand auch im dry_run). So bleibt die `needs`-Kette intakt. Nur die *terminalen* Jobs (`release`/sign-publish, `cleanup`) tragen ein Job-Level-`if`.

Jobs:
1. **validate-tag** (läuft immer; Steps `if: !dry_run`) — **NEU**, der vom User gewünschte Format-Gate:
   - `github.ref` muss mit `refs/tags/` beginnen, sonst Abbruch.
   - `github.ref_name` muss `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}[a-z]?$` matchen (dieselbe `TAG_RE` wie `compute-release-version.sh`), sonst Abbruch.
   - Grund: `workflow_dispatch` kann von Hand gegen einen beliebigen Ref ausgelöst werden; der Signier-/Publish-Pfad darf nur für einen korrekt geformten Tag laufen. Im dry_run (Branch-Ref) ist der Check-Step übersprungen.
   - **`release_tag`-Output:** real run → `github.ref_name` (der validierte Tag); dry_run → `dev`. Ein Branch-`ref_name` kann `/` enthalten (`feature/foo`), das BitBake für `OE5XRX_RELEASE_TAG` (`[A-Za-z0-9._-]`) fatal ablehnt — `dev` ist der Dev-Build-Stamp, den Image + boot-ota-Tests kennen.
2. **preflight** (`needs: validate-tag`; läuft **immer, unconditionally** — die Reusable nimmt kein `dry_run`) — wie Flow 1, am getaggten Commit (Defense-in-depth).
3. **resolve-slot-a** — Vorgänger-Release (`gh release list -L 1 …`) fürs Gate. Der aktuelle Tag hat noch **kein** Release (wird erst in sign-publish erzeugt), also liefert das korrekt das vorige Release als Slot A.
4. **build-x64** / **build-rpi** (`uses: ./.github/workflows/build.yml`) — `release_tag: ${{ needs.validate-tag.outputs.release_tag }}` (Tag im real run, `dev` im dry_run); Checkout am Tag-Ref (implizit, da der Run auf dem Tag läuft).
5. **gate** (`uses: ./.github/workflows/boot-ota-test.yml`) — `expected_tag: ${{ needs.validate-tag.outputs.release_tag }}` (**derselbe** aufgelöste Wert wie der Build-Stamp, damit die Versions-Assertion auch im dry_run matcht), `last_release_tag` aus resolve-slot-a.
6. **release** / sign-publish (`needs: [validate-tag, build-x64, build-rpi, gate]`, `if: !dry_run`):
   - Artefakte laden, `cosign sign-blob` — läuft jetzt unterm **Tag-Ref → Identity `@refs/tags/<tag>`**.
   - `softprops/action-gh-release@v3` mit `tag_name: ${{ github.ref_name }}` (Tag existiert bereits → Release wird an ihn gehängt).
7. **cleanup** — Tag löschen, wenn ein **echter Arbeits-Job** fehlschlägt. Statt eines nackten `failure()` (das per GitHub-Semantik bei *jedem* Ancestor-Fehler — inkl. `validate-tag` transitiv über `preflight` — feuert und so bei einem malformed-Tag-Dispatch einen fremden Tag löschen würde) explizit: `always() && !dry_run && startsWith(github.ref,'refs/tags/') && needs.validate-tag.result=='success' && (needs.preflight/resolve-slot-a/build-x64/build-rpi/gate/release … == 'failure')`. Delete ist `git ls-remote`-guarded (nur echte Fehler schlagen durch, „already gone" ist No-op).

`permissions`: `contents: write` (Release + Tag löschen), `id-token: write` (cosign), `actions: read`.

### dry_run
Manuell `gh workflow run release.yml --ref <branch> -f dry_run=true` → `validate-tag`/`preflight`/`sign-publish`/`cleanup` werden via `if:` übersprungen; nur build-x64/rpi + gate laufen (Pipeline-Validierung vom Branch, ohne Tag/Signatur/Publish). Entspricht dem heutigen dry_run-Verhalten.

## Reuse / unverändert
- `./.github/workflows/build.yml`, `./.github/workflows/boot-ota-test.yml`, `./.github/actions/compute-version` bleiben wie sie sind (nur andere Aufrufer/Inputs).
- `compute-release-version.sh` `TAG_RE` ist die Single-Source für das Format; `validate-tag` verwendet dieselbe Regex (inline in YAML, mit Kommentar-Verweis).
- **FW-RemoteStation-Verifikation** (`bump-fw-release.sh --check`, `@refs/heads/main`) bleibt — das ist ein anderes Repo, dessen Signaturidentity sich nicht ändert.
- **station-manager** wird nicht angefasst; dessen `@refs/tags/{tag}`-Erwartung wird durch diesen Umbau wieder korrekt.

## Concurrency
- Flow 2 behält `concurrency: { group: release, cancel-in-progress: false }` (nur eine echte Release-Pipeline gleichzeitig).
- Flow 1 bekommt eine **eigene** Gruppe (`group: tag-release`) — kurz laufend; kein Deadlock mit Flow 2.

## Betrieb / Semantik
- **Retry:** Bei Flow-2-Fehler löscht cleanup den Tag. „Re-run" von Flow 2 liefe gegen einen gelöschten Ref → **stattdessen Flow 1 neu dispatchen** (berechnet neuen Tag; ggf. Buchstaben-Suffix bei gleicher Stunde). Wird in der Workflow-Beschreibung dokumentiert.
- **Fenster:** Zwischen Tag-Erzeugung (Flow 1) und Publish (Ende Flow 2) existiert der Tag ohne Release. station-manager importiert per *Release*, sieht also nichts Halbfertiges.
- **Altes Release `2026.07.22-07`** (noch `@main` signiert) bleibt unverändert; es verifiziert nicht in station-manager. Erst das nächste über diesen Flow erzeugte Release ist importierbar/deploybar.

## Verifikation
- YAML-Lint / `actionlint` auf beide Workflows.
- **Tragende Annahme (erster echter Run):** ein `workflow_dispatch` gegen einen Tag-Ref erzeugt cosign-SAN `@refs/tags/<tag>` (nicht `@main`). Niedriges Risiko — genau das produzierte linux-image früher tag-getriggert (daher station-managers Erwartung). Erster Real-Run: cosign-Cert-SAN prüfen bzw. den anschließenden station-manager-Import erfolgreich durchlaufen lassen.
- End-to-End-Beweis: neues Release cutten → in station-manager importieren → `cosign verify-blob` grün → OTA-Deploy auf die Station.

## Bewusst außerhalb Scope
- station-manager-Änderungen (keine).
- Rückwirkendes Neu-Signieren alter Releases.
