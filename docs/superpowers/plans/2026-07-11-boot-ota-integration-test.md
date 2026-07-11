# Boot & OTA Integration Test — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A QEMU boot + cross-build A/B OTA integration test for the OE5XRX Linux image that would have caught the two shipped OTA bugs (#36 fs-label, #37 ESP-by-UUID), plus build-time guards and a reworked one-button release gated on the test.

**Architecture:** A standalone stdlib **dummy OTA server** speaks the agent's real protocol; a **`Target`** abstraction (QemuTarget now, Cm4Target future) boots the image and reaches its console; **pytest+pexpect** tests assert both a serial banner+login AND an agent check-in/commit. Cheap static/build guards catch the UUID-mount class. The release workflow becomes `workflow_dispatch` with a self-computed version, gated on the test.

**Tech Stack:** Python 3 (stdlib `http.server`, `bz2`, `hashlib`; pytest; pexpect; pyyaml; `cryptography` for Ed25519), QEMU (`qemu-system-x86_64`, OVMF, TCG), GitHub Actions (reusable workflows + composite action), BitBake/wic (Yocto scarthgap).

## Global Constraints

- **Repo:** all work in `/home/pbuchegger/OE5XRX/linux-image` on branch `test/boot-ota-integration` (already checked out; spec already committed).
- **Test package root:** `tests/ota-integration/` (mirrors existing `tests/sim-harness/`).
- **No new heavy deps:** dummy server = stdlib only. Harness may use `pytest`, `pexpect`, `pyyaml`, `cryptography` (all pip-installable in CI).
- **Condition-based waits only** in the harness (pexpect `expect`, never fixed `sleep`), generous TCG timeouts.
- **Image stays unmodified** — only the data partition carries test config (`Target.seed_config`).
- **Runner is a parameter** — `boot-ota-test.yml` takes `runner_label`, default GH-hosted `ubuntu-latest`.
- **Cross-build is mandatory for T2** — slot A = last published release, slot B = the build under test. Never same-build (would hide the UUID bug).
- **Commit style:** end commit messages with `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`. Do NOT merge to main (user reviews the PR).

## Protocol Reference (ground truth — the dummy server MUST match)

Agent lives in `station-manager/station_agent/`; contract verified against it and `station-manager/apps/`.

**Auth (agent → server, every request):** headers `Authorization: DeviceKey <station_id>`, `X-Device-Signature: <b64>`, `X-Device-Timestamp: <stringified-float>`. **The agent never validates server responses beyond `status_code`.** → the dummy IGNORES all auth headers and just returns the bodies below.

**Endpoints (all under `<server_url>/api/v1/`):**

1. `POST /heartbeat/` — req body has `hostname, os_version (=PRETTY_NAME), uptime, ip_address, agent_version, module_versions, inventory, timestamp`. Resp: **200** `{"status":"ok"}`. Agent reads only the status code.
2. `POST /deployments/check/` — req `{"current_version": "<PRETTY_NAME or tag>"}`. Resp: **204** = no update; or **200** with:
   ```json
   {"deployment_result_id": 1, "deployment_id": 1, "deployment_result_status": "pending",
    "target_tag": "2026.07.11-15", "checksum_sha256": "<64hex>", "size_bytes": 12345,
    "download_url": "/api/v1/deployments/1/download/"}
   ```
   `deployment_result_id` is used in the status path; `deployment_id` in the download_url; agent uses `download_url` **verbatim**. To trigger the post-reboot branch, return `deployment_result_status` = `"rebooting"` or `"verifying"` (agent then skips download and goes to verify+commit).
3. `GET <download_url>` — serve the **rootfs bz2** (see payload note) with correct `Content-Length`. Simplest faithful behavior: **ignore Range, always 200 full body**; the agent restarts-from-zero if it sent a Range. Content-Type `application/x-bzip2`.
4. `POST /deployments/<result_pk>/status/` — req `{"status": "<s>", "error_message": "<...>"}`, `<s>` ∈ {downloading, installing, rebooting, verifying, failed, rolled_back}. Resp **200** `{"status":"ok"}`.
5. `POST /deployments/commit/` — req `{"version": "<target_tag>"}`. Resp **200** `{"status":"ok"}`. The `version` MUST equal the advertised `target_tag`.

**OTA success sequence:** heartbeat(s) → check(200, status=pending) → status(downloading) → GET download → status(installing) → status(rebooting) → **reboot** → heartbeat → check(200, status=rebooting) → status(verifying) → commit(version=target_tag). Failure emits `failed`/`rolled_back` on `/status/`.

**Checksum:** `checksum_sha256` in the check response = SHA-256 of the **compressed bz2 bytes** the agent downloads (verified before decompression). Empty string = agent skips verification.

**Timers:** agent `heartbeat_interval` (min 10s), `ota_check_interval` = "check every N heartbeats" (default 5). Test config sets `heartbeat_interval: 10`, `ota_check_interval: 1` → OTA check every ~10 s.

## Payload note (OTA download content)

The build produces `*.rootfs.wic` and `*.rootfs.wic.bz2` (IMAGE_FSTYPES = `wic wic.bz2`), **no standalone rootfs ext4**. The server, at ImageRelease import, extracts the **root_a partition** (an ext4 rootfs) from the wic and serves it bz2-compressed; the agent decompresses that into `root_<slot>`. The harness must mirror this: **extract partition 2 (`root_a`, the ext4 rootfs) from the build's wic, bz2-compress it, and compute its sha256** — that (compressed) blob + sha256 is what the dummy serves and advertises. (Partition order from `oe5xrx-remotestation-ab-x64.wks.in`: 1=`efi`, 2=`root_a`, 3=`root_b`, 4=`data`.)

## grubenv / A/B state (x86)

grubenv lives at `/boot/EFI/BOOT/grubenv` (ESP, PARTLABEL `efi`, partition 1). Vars: `boot_part` (a|b), `bootcount`, `upgrade_available` (1=trial,0=committed), `bootlimit` (3). Committed default: `boot_part=a bootcount=0 upgrade_available=0 bootlimit=3`. GRUB increments bootcount every boot and, if `upgrade_available=1 && bootcount>bootlimit`, swaps `boot_part` and clears the trial (rollback). Read/reset from the host by mounting partition 1 (FAT) and rewriting `EFI/BOOT/grubenv`, or via `grub-editenv` in-guest.

## QEMU invocation (mirror `scripts/run-qemu.sh`, headless + pty serial)

```
qemu-system-x86_64 [-enable-kvm if /dev/kvm] -cpu IvyBridge -machine q35 \
  -m 1024 -smp 2 -nographic \
  -serial pty  (harness reads the reported /dev/pts/N; NOT mon:stdio) \
  -drive if=pflash,format=raw,readonly=on,file=<OVMF_CODE.fd> \
  -drive if=pflash,format=raw,file=<per-run copy of OVMF_VARS.fd> \
  -drive file=<per-run copy of the .wic>,if=virtio,format=raw \
  -device virtio-net-pci,netdev=n0 \
  -netdev user,id=n0,hostfwd=tcp::<sshport>-:22
```
OVMF_CODE probe order: `/usr/share/OVMF/OVMF_CODE_4M.fd`, `/usr/share/OVMF/OVMF_CODE.fd`, `/usr/share/edk2-ovmf/x64/OVMF_CODE.fd`. OVMF_VARS: copy a `*_VARS*.fd` template per run (writable). The wic passed to `-drive` must be **decompressed**. The guest reaches the host dummy server at `http://10.0.2.2:<dummy_port>` (SLIRP alias). Each run: unique dummy port + sshport + tmp dir.

---

## File Structure

```
tests/ota-integration/
  __init__.py
  README.md                      # how to run locally + in CI
  requirements.txt               # pytest, pexpect, pyyaml, cryptography
  pytest.ini                     # markers: qemu (needs qemu+root), unit
  dummy_server.py                # DummyOtaServer: endpoints + recorded state
  target.py                      # Target ABC + QemuTarget (+ Cm4Target stub)
  image_ops.py                   # extract_rootfs_bz2(), sha256_file(), decompress_wic()
  seed.py                        # render_config_yaml(), gen_ed25519_key(), seed_data_partition()
  conftest.py                    # fixtures: dummy_server, qemu_target, artifacts
  test_dummy_server.py           # UNIT: drive the dummy directly, assert recorded state
  test_image_ops.py              # UNIT: rootfs extraction / sha256 / config render
  test_boot.py                   # T1 (marker: qemu)
  test_ota_cycle.py              # T2 (marker: qemu)
  test_rollback.py               # T3 (marker: qemu)
scripts/
  l0a-fstab-uuid-lint.sh         # static wks/recipe UUID-pattern lint (every PR)
  compute-release-version.sh     # next YYYY.MM.DD-HH[a-z]; used by the composite action
.github/actions/compute-version/action.yml   # composite action wrapping the script
.github/workflows/
  ci.yml                         # MODIFY: add L0a job/step
  boot-ota-test.yml              # NEW reusable (workflow_call): runs pytest -m qemu
  boot-ota-pr.yml                # NEW: path-filtered PR trigger → build + boot-ota-test
  release.yml                    # MODIFY: workflow_dispatch + compute-version + gate
  boot-ota-spike.yml             # NEW: workflow_dispatch feasibility spike (TCG boot timing)
meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb  # MODIFY: L0b assertion
scripts/release.sh               # MODIFY: reduce to a `gh workflow run` dispatcher
```

---

## Task 1: Test package scaffold

**Files:**
- Create: `tests/ota-integration/__init__.py` (empty), `tests/ota-integration/requirements.txt`, `tests/ota-integration/pytest.ini`, `tests/ota-integration/README.md`

**Interfaces:**
- Produces: the package dir + `pytest -m unit` runnable (no tests yet → exit 5 is fine).

- [ ] **Step 1: Create requirements.txt**
```
pytest>=8
pexpect>=4.9
pyyaml>=6
cryptography>=43
```
- [ ] **Step 2: Create pytest.ini**
```ini
[pytest]
markers =
    unit: pure unit tests, no QEMU/root needed
    qemu: needs qemu-system-x86_64 + root (loop mount); run in CI or on a capable host
addopts = -ra
```
- [ ] **Step 3: Create `__init__.py` (empty) and a short README.md** documenting: `pip install -r requirements.txt`; `pytest -m unit` (fast, local); `sudo pytest -m qemu` (needs qemu+OVMF+root); env knobs (`OTA_IT_WIC`, `OTA_IT_LAST_RELEASE_WIC`).
- [ ] **Step 4: Commit**
```bash
git add tests/ota-integration/
git commit -m "test(ota-it): scaffold ota-integration package"
```

---

## Task 2: Dummy OTA server (TDD, unit-tested)

**Files:**
- Create: `tests/ota-integration/dummy_server.py`
- Test: `tests/ota-integration/test_dummy_server.py`

**Interfaces:**
- Produces:
  - `class DummyOtaServer(payload_path: str|None, checksum: str|None, size: int|None, target_tag: str)` with:
    - `.start() -> None` / `.stop() -> None` (background `http.server.ThreadingHTTPServer`)
    - `.url -> str` (e.g. `http://127.0.0.1:<port>`; bind `0.0.0.0`, report chosen port)
    - `.port -> int`
    - `.offer_update: bool` (default False; when True `/check/` returns 200)
    - `.result_status: str` (what `/check/` reports; default `"pending"`, set to `"rebooting"` to drive post-reboot branch)
    - recorded state: `.heartbeats: list[dict]`, `.status_updates: list[dict]`, `.commits: list[dict]`, `.downloads: int`
    - `.last_reported_version() -> str|None` (from the most recent commit)

- [ ] **Step 1: Write failing unit tests** `test_dummy_server.py` (marker `unit`):
```python
import json, urllib.request
import pytest
from tests.ota_integration.dummy_server import DummyOtaServer

pytestmark = pytest.mark.unit

def _post(url, obj):
    data = json.dumps(obj).encode()
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return r.status, r.read()

def test_heartbeat_records_and_returns_ok():
    s = DummyOtaServer(payload_path=None, checksum=None, size=None, target_tag="T"); s.start()
    try:
        st, body = _post(s.url + "/api/v1/heartbeat/", {"os_version": "OE5XRX Remote Station T"})
        assert st == 200 and json.loads(body) == {"status": "ok"}
        assert s.heartbeats[-1]["os_version"] == "OE5XRX Remote Station T"
    finally:
        s.stop()

def test_check_204_when_no_update():
    s = DummyOtaServer(payload_path=None, checksum=None, size=None, target_tag="T"); s.start()
    try:
        req = urllib.request.Request(s.url + "/api/v1/deployments/check/",
              data=b'{"current_version":"X"}', method="POST",
              headers={"Content-Type": "application/json"})
        try:
            urllib.request.urlopen(req)
            assert False, "expected 204"
        except urllib.error.HTTPError as e:
            assert e.code == 204
    finally:
        s.stop()

def test_check_200_offers_update_with_expected_fields(tmp_path):
    payload = tmp_path / "rootfs.bz2"; payload.write_bytes(b"hello-bz2")
    s = DummyOtaServer(payload_path=str(payload), checksum="deadbeef",
                       size=9, target_tag="2026.07.11-15")
    s.offer_update = True; s.start()
    try:
        st, body = _post(s.url + "/api/v1/deployments/check/", {"current_version": "old"})
        d = json.loads(body)
        assert st == 200
        assert d["target_tag"] == "2026.07.11-15"
        assert d["checksum_sha256"] == "deadbeef"
        assert d["size_bytes"] == 9
        assert d["download_url"].endswith("/download/")
        assert "deployment_result_id" in d and "deployment_id" in d
    finally:
        s.stop()

def test_download_serves_payload_bytes(tmp_path):
    payload = tmp_path / "rootfs.bz2"; payload.write_bytes(b"PAYLOAD")
    s = DummyOtaServer(payload_path=str(payload), checksum="x", size=7, target_tag="T")
    s.offer_update = True; s.start()
    try:
        st, body = _post(s.url + "/api/v1/deployments/check/", {"current_version": "old"})
        url = json.loads(body)["download_url"]
        with urllib.request.urlopen(s.url + url) as r:
            assert r.status == 200 and r.read() == b"PAYLOAD"
        assert s.downloads == 1
    finally:
        s.stop()

def test_status_and_commit_recorded():
    s = DummyOtaServer(payload_path=None, checksum=None, size=None, target_tag="2026.07.11-15")
    s.start()
    try:
        _post(s.url + "/api/v1/deployments/1/status/", {"status": "downloading", "error_message": ""})
        st, _ = _post(s.url + "/api/v1/deployments/commit/", {"version": "2026.07.11-15"})
        assert st == 200
        assert s.status_updates[-1]["status"] == "downloading"
        assert s.last_reported_version() == "2026.07.11-15"
    finally:
        s.stop()
```
- [ ] **Step 2: Run to confirm failure** — `cd /home/pbuchegger/OE5XRX/linux-image && python -m pytest tests/ota-integration/test_dummy_server.py -q` → FAIL (ImportError). (Add a `conftest.py`/`sys.path` shim or run with `PYTHONPATH=.`; use package import `tests.ota_integration...` — ensure `tests/__init__.py` and `tests/ota_integration` importability, or switch tests to `from dummy_server import ...` with `rootdir` on path. Pick one and be consistent.)
- [ ] **Step 3: Implement `dummy_server.py`** — a `ThreadingHTTPServer` + `BaseHTTPRequestHandler`. Route on `self.path` and method. `/api/v1/heartbeat/` → record JSON body, 200 `{"status":"ok"}`. `/api/v1/deployments/check/` → if `offer_update`: 200 with the dict (using `result_status`, `download_url = f"/api/v1/deployments/{deployment_id}/download/"`), else 204. `GET .../download/` → read `payload_path`, send 200 with `Content-Length` + `Content-Type: application/x-bzip2`, increment `downloads`. `/api/v1/deployments/<pk>/status/` → append to `status_updates`, 200. `/api/v1/deployments/commit/` → append to `commits`, 200. Ignore all auth headers. Bind to `("0.0.0.0", 0)`, read back `server_address[1]` for `.port`; `.url` uses `127.0.0.1` for local tests (the guest uses 10.0.2.2 separately — the URL the guest sees is set via config, not `.url`). Silence base logging.
- [ ] **Step 4: Run tests to pass** — `python -m pytest tests/ota-integration/test_dummy_server.py -q` → PASS.
- [ ] **Step 5: Commit** — `git add tests/ota-integration/{dummy_server.py,test_dummy_server.py} && git commit -m "test(ota-it): dummy OTA server speaking the agent protocol"`

---

## Task 3: Image ops — rootfs extraction, sha256, config render (TDD, unit where possible)

**Files:**
- Create: `tests/ota-integration/image_ops.py`, `tests/ota-integration/seed.py`
- Test: `tests/ota-integration/test_image_ops.py`

**Interfaces:**
- Produces:
  - `image_ops.sha256_file(path) -> str`
  - `image_ops.bz2_compress(src, dst) -> None`
  - `image_ops.extract_rootfs_bz2(wic_path, out_bz2) -> tuple[str, int]` — extracts partition 2 (`root_a`) from the wic, bz2-compresses it to `out_bz2`, returns `(sha256_hex, size_bytes)` of the **compressed** file. Uses `losetup --find --show --partscan` + `dd`/stream through `bz2`; requires root. Guarded so unit runs can skip.
  - `seed.render_config_yaml(server_url, station_id=1, key_path="/etc/stationagent/device_key.pem") -> str` (includes `heartbeat_interval: 10`, `ota_check_interval: 1`, `bootloader: grub`)
  - `seed.gen_ed25519_key(dest_pem_path) -> None` (PEM private key via `cryptography`)
  - `seed.seed_data_partition(wic_path, config_yaml_text, key_pem_path) -> None` — loop-mount partition 4 (`data`), `mkdir -p etc-overlay/stationagent`, write `config.yml` (0600) + `device_key.pem`; root-only.
  - `image_ops.decompress_wic(bz2_or_wic_path, out_wic) -> str` — if `.bz2`, stream-decompress; else copy. Returns out path.

- [ ] **Step 1: Write failing unit tests** (`unit` marker) for the pure functions:
```python
import bz2, hashlib, pytest, yaml
from tests.ota_integration import image_ops, seed
pytestmark = pytest.mark.unit

def test_sha256_file(tmp_path):
    p = tmp_path/"f"; p.write_bytes(b"abc")
    assert image_ops.sha256_file(str(p)) == hashlib.sha256(b"abc").hexdigest()

def test_bz2_roundtrip(tmp_path):
    src = tmp_path/"s"; src.write_bytes(b"x"*1000); dst = tmp_path/"s.bz2"
    image_ops.bz2_compress(str(src), str(dst))
    assert bz2.decompress(dst.read_bytes()) == b"x"*1000

def test_render_config_yaml_has_tuned_timers():
    txt = seed.render_config_yaml("http://10.0.2.2:8080")
    d = yaml.safe_load(txt)
    assert d["server_url"] == "http://10.0.2.2:8080"
    assert d["heartbeat_interval"] == 10 and d["ota_check_interval"] == 1
    assert d["station_id"] == 1 and d["bootloader"] == "grub"

def test_gen_ed25519_key_writes_pem(tmp_path):
    dst = tmp_path/"k.pem"; seed.gen_ed25519_key(str(dst))
    assert dst.read_bytes().startswith(b"-----BEGIN PRIVATE KEY-----")

def test_decompress_wic_passthrough_and_bz2(tmp_path):
    raw = tmp_path/"a.wic"; raw.write_bytes(b"WIC")
    assert open(image_ops.decompress_wic(str(raw), str(tmp_path/"o1.wic")),"rb").read() == b"WIC"
    comp = tmp_path/"b.wic.bz2"; comp.write_bytes(bz2.compress(b"WIC2"))
    assert open(image_ops.decompress_wic(str(comp), str(tmp_path/"o2.wic")),"rb").read() == b"WIC2"
```
- [ ] **Step 2: Run → FAIL** (ImportError / not implemented).
- [ ] **Step 3: Implement `image_ops.py` + `seed.py`.** Pure funcs as above. `extract_rootfs_bz2` and `seed_data_partition` use `subprocess` (`losetup`, `mount`, `umount`) with a context manager that always detaches the loop device and unmounts (finally). `render_config_yaml` builds the dict and `yaml.safe_dump`s it.
- [ ] **Step 4: Run → PASS** (unit subset; the root-requiring funcs are covered later by the qemu-marked flow).
- [ ] **Step 5: Commit** — `git commit -m "test(ota-it): image ops (rootfs extract, sha256, config seed helpers)"`

---

## Task 4: `Target` interface + `QemuTarget` + Cm4Target stub

**Files:**
- Create: `tests/ota-integration/target.py`

**Interfaces:**
- Consumes: `image_ops`, `seed`.
- Produces:
  - `class Target(ABC)` with abstract methods: `flash(wic_path)`, `seed_config(config_yaml, key_pem)`, `power_on()`, `power_off()`, `reset()`, `console() -> pexpect.spawn-like`, `dut_server_url(dummy_port) -> str`, `boot_markers() -> dict` (keys: `banner_re`, `login_re`), and `reset_ab_state()` (set grubenv committed slot-A).
  - `class QemuTarget(Target)`:
    - ctor `(work_dir, mem=1024, cpus=2)`; discovers OVMF; allocates a free ssh port.
    - `flash(wic)` = copy the (decompressed) wic into `work_dir` as the per-run disk; `power_on` launches qemu with `-serial pty`, parses the `char device redirected to /dev/pts/N` line, opens a `pexpect.fdpexpect`/`pexpect.spawn` on it.
    - `dut_server_url(port)` = `f"http://10.0.2.2:{port}"`.
    - `boot_markers()` = `{"banner_re": r"OE5XRX Remote Station (\S+)", "login_re": r"login:"}`.
    - `reset_ab_state()` / `seed_config` call `seed.seed_data_partition` / a grubenv reset on the per-run disk (loop-mount, root).
  - `class Cm4Target(Target)` — **stub**: every method raises `NotImplementedError("CM4 bench: future work")`, with a module docstring pointing at the spec's CM4 section. Exists so the interface is real and imports don't break.

- [ ] **Step 1:** Write a `unit`-marked test asserting the interface shape only: `QemuTarget.boot_markers()` returns the two regexes; `dut_server_url(8080) == "http://10.0.2.2:8080"`; `Cm4Target().flash("x")` raises `NotImplementedError`. (No QEMU launched.)
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement `target.py`. Keep QEMU-launch code in `power_on` (not exercised by unit tests). Use the exact qemu args from the Protocol Reference. Detect `/dev/kvm` and add `-enable-kvm` only if present (TCG otherwise).
- [ ] **Step 4:** Run unit test → PASS.
- [ ] **Step 5:** Commit — `git commit -m "test(ota-it): Target interface + QemuTarget + Cm4Target stub"`

---

## Task 5: Fixtures + T1 (boot smoke) — qemu-marked

**Files:**
- Create: `tests/ota-integration/conftest.py`, `tests/ota-integration/test_boot.py`

**Interfaces:**
- Consumes: `DummyOtaServer`, `QemuTarget`, `image_ops`, `seed`.
- Produces: fixtures `built_wic` (env `OTA_IT_WIC` → decompressed path), `qemu_target`, `dummy` (started server). T1 test.

- [ ] **Step 1:** Write `test_boot.py` (marker `qemu`):
```python
import os, re, pytest
pytestmark = pytest.mark.qemu

def test_t1_boots_and_agent_checks_in(qemu_target, dummy, built_wic):
    # dummy offers NO update; agent must just boot + heartbeat.
    tag = os.environ["OTA_IT_EXPECTED_TAG"]  # dev-stamp or release tag
    qemu_target.flash(built_wic)
    qemu_target.reset_ab_state()
    url = qemu_target.dut_server_url(dummy.port)
    from tests.ota_integration import seed
    cfg = seed.render_config_yaml(url)
    keyp = qemu_target.work_dir + "/device_key.pem"; seed.gen_ed25519_key(keyp)
    qemu_target.seed_config(cfg, keyp)
    con = qemu_target.power_on()
    m = qemu_target.boot_markers()
    con.expect(m["banner_re"], timeout=900)   # banner carries the version
    banner_ver = con.match.group(1).decode() if isinstance(con.match.group(1), bytes) else con.match.group(1)
    con.expect(m["login_re"], timeout=120)
    # agent must check in at the expected version
    _wait_until(lambda: any(tag in (h.get("os_version") or "") for h in dummy.heartbeats), 300)
    assert any(tag in (h.get("os_version") or "") for h in dummy.heartbeats)
    assert tag in banner_ver or banner_ver in tag
```
(`_wait_until` = poll helper in conftest; condition-based, generous timeout.)
- [ ] **Step 2:** Run → FAIL/SKIP without a wic. Document: T1 requires `OTA_IT_WIC` + `OTA_IT_EXPECTED_TAG` + root + qemu.
- [ ] **Step 3:** Implement `conftest.py` fixtures + `_wait_until`. `built_wic` decompresses `OTA_IT_WIC` via `image_ops.decompress_wic`. `dummy` yields a started `DummyOtaServer` (offer_update False for T1). `qemu_target` yields a `QemuTarget(tmp work dir)`, teardown kills qemu + detaches loops.
- [ ] **Step 4:** (CI-only) verify green in the `boot-ota-test.yml` run (Task 9). Locally, `pytest -m unit` still passes; `-m qemu` skipped without env.
- [ ] **Step 5:** Commit — `git commit -m "test(ota-it): T1 boot smoke + fixtures"`

---

## Task 6: T2 (cross-build OTA cycle) + T3 (rollback) — qemu-marked

**Files:**
- Create: `tests/ota-integration/test_ota_cycle.py`, `tests/ota-integration/test_rollback.py`

**Interfaces:**
- Consumes: everything above. Env: `OTA_IT_LAST_RELEASE_WIC` (slot A = previous release), `OTA_IT_WIC` (slot B = build under test), `OTA_IT_EXPECTED_TAG` (new tag).

- [ ] **Step 1: T2** (`test_ota_cycle.py`, marker `qemu`): flash the **last-release** wic; extract `root_a` from the **new build** wic → bz2 + sha256 (`image_ops.extract_rootfs_bz2`); configure `dummy` with that payload, `offer_update=True`, `target_tag=<new>`, `result_status="pending"`. Boot last-release; wait for the agent to check in, download (`dummy.downloads >= 1`), and post `installing`/`rebooting` (`dummy.status_updates`). When the guest reboots, flip `dummy.result_status="rebooting"` so the post-reboot check drives verify+commit. Assert: after reboot the banner shows the **new** tag + login; `dummy.last_reported_version() == <new tag>` and a `commit` was recorded. Add the code comment: *"Slot A MUST be a DIFFERENT build than slot B (last release vs build-under-test) — same-build hides the ESP-UUID bug (#37)."*
- [ ] **Step 2: T3** (`test_rollback.py`, marker `qemu`): same setup but serve a **deliberately broken** rootfs (e.g. truncate/zero the payload so the slot is unbootable) OR withhold the commit and let bootcount exceed bootlimit; assert the guest reverts to slot A (banner shows the **old** tag) and the agent reports `rolled_back` (in `dummy.status_updates`).
- [ ] **Step 3:** Run locally `-m unit` (unaffected). `-m qemu` runs in CI.
- [ ] **Step 4:** Commit — `git commit -m "test(ota-it): T2 cross-build OTA + T3 rollback"`

---

## Task 7: L0a static UUID-pattern lint (every PR) + L0b build assertion

**Files:**
- Create: `scripts/l0a-fstab-uuid-lint.sh`, `tests/ota-integration/test_l0a_lint.py`
- Modify: `meta-oe5xrx-remotestation/recipes-core/images/oe5xrx-remotestation-image.bb` (add L0b)

**Interfaces:**
- Produces: `l0a-fstab-uuid-lint.sh <repo-root>` exits non-zero if any wks `part` with a mountpoint uses `--use-uuid` **without** `--no-fstab-update`, or any recipe writes a `UUID=` fstab line. Prints offending file:line.

- [ ] **Step 1:** Write `test_l0a_lint.py` (`unit`): create a temp wks with `part /boot ... --use-uuid` (no `--no-fstab-update`) → assert the script exits non-zero; a temp wks with `--use-uuid --no-fstab-update` → exits zero; a clean tree → zero. Invoke via `subprocess`.
- [ ] **Step 2:** Run → FAIL (script missing).
- [ ] **Step 3:** Implement `l0a-fstab-uuid-lint.sh` (bash, `set -euo pipefail`): scan `meta-*/wic/*.wks*` for lines matching `^part .*/[^ ]* .*--use-uuid` that do NOT contain `--no-fstab-update`; grep recipes for `UUID=` writes into fstab. Emit `::error file=...::` lines and exit 1 on any hit. **Run it on the current tree — it must exit 0** (the #37 fix already added `--no-fstab-update`).
- [ ] **Step 4:** Run test → PASS; run `scripts/l0a-fstab-uuid-lint.sh .` → exit 0.
- [ ] **Step 5: L0b** — in the image recipe, add a `python assert_no_uuid_fstab()` ROOTFS_POSTPROCESS that reads `${IMAGE_ROOTFS}/etc/fstab` and `bb.fatal`s if any non-comment line's device field matches `UUID=` or `/dev/disk/by-uuid/`. Append `ROOTFS_POSTPROCESS_COMMAND += "assert_no_uuid_fstab;"`. (Mirrors the existing `fix_firmware_fstab`/`add_efi_fstab` style.)
- [ ] **Step 6:** Commit — `git commit -m "test(ota-it): L0a UUID-pattern lint + L0b fstab build assertion"`

---

## Task 8: `compute-release-version.sh` + composite action (TDD)

**Files:**
- Create: `scripts/compute-release-version.sh`, `.github/actions/compute-version/action.yml`, `tests/ota-integration/test_compute_version.py`

**Interfaces:**
- Produces: `compute-release-version.sh` prints the next `YYYY.MM.DD-HH[a-z]` to stdout. Given an env/arg list of "existing tags" (for testability) it computes: `base=$(date -u +%Y.%m.%d-%H)`; if no existing tag == base → `base`; else next free `[a-z]` suffix (`base` a? then b? …); error at `z`. Accept existing tags via `--existing "<newline-list>"` (default: `git tag -l "${base}*"`) so tests don't touch git.

- [ ] **Step 1:** Write `test_compute_version.py` (`unit`): call the script with `--now 2026.07.11-15 --existing ""` → `2026.07.11-15`; `--existing "2026.07.11-15"` → `2026.07.11-15a`; `--existing $'2026.07.11-15\n2026.07.11-15a'` → `2026.07.11-15b`; unrelated tags ignored. (Add `--now` to inject the base for deterministic tests.)
- [ ] **Step 2:** Run → FAIL.
- [ ] **Step 3:** Implement the script (bash). Mirror `scripts/release.sh` letter-progression (`tr 'a-y' 'b-z'`) but computed against the `--existing` list. Validate output against `^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9]{2}[a-z]?$`.
- [ ] **Step 4:** Run → PASS.
- [ ] **Step 5:** Create `.github/actions/compute-version/action.yml` (composite): `git fetch --tags --quiet`, run the script, set output `version`. 
- [ ] **Step 6:** Commit — `git commit -m "ci(release): compute-version script + composite action"`

---

## Task 9: `boot-ota-test.yml` reusable workflow

**Files:**
- Create: `.github/workflows/boot-ota-test.yml`

**Interfaces:**
- `workflow_call` inputs: `machine` (default `qemux86-64`), `runner_label` (default `ubuntu-latest`), `new_artifact` (the `yocto-image-<machine>` artifact name from the same run), `expected_tag`, `last_release_tag` (optional; empty → skip T2, run T1 only — bootstrap case).

- [ ] **Step 1:** Write `boot-ota-test.yml`: `runs-on: ${{ inputs.runner_label }}`. Steps: checkout; `sudo apt-get install -y qemu-system-x86 ovmf python3-pip`; `pip install -r tests/ota-integration/requirements.txt`; `download-artifact` the new build wic → set `OTA_IT_WIC`; if `last_release_tag` non-empty, `gh release download <last_release_tag> --pattern '*qemux86-64*.wic.bz2'` → `OTA_IT_LAST_RELEASE_WIC`; set `OTA_IT_EXPECTED_TAG`; run `sudo -E env "PATH=$PATH" python -m pytest tests/ota-integration -m qemu -v` (T2/T3 auto-skip if `OTA_IT_LAST_RELEASE_WIC` unset via a `skipif`). Add a job-level `timeout-minutes: 60`.
- [ ] **Step 2:** `actionlint`/`yamllint` it (mirror ci.yml's yamllint invocation) → clean.
- [ ] **Step 3:** Commit — `git commit -m "ci: reusable boot-ota-test workflow (runner-parametrized)"`

---

## Task 10: `boot-ota-pr.yml` (path-filtered PR) + `ci.yml` L0a

**Files:**
- Create: `.github/workflows/boot-ota-pr.yml`
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1:** `boot-ota-pr.yml`: `on: pull_request: paths: [meta-oe5xrx-remotestation/wic/**, meta-oe5xrx-remotestation/recipes-bsp/**, meta-oe5xrx-remotestation/recipes-core/ab-layout/**, meta-oe5xrx-remotestation/recipes-core/images/**, meta-oe5xrx-remotestation/recipes-core/station-agent/**, tests/ota-integration/**, .github/workflows/boot-ota-*.yml]`. Job `build-x64` → `uses: ./.github/workflows/build.yml` with `machine: qemux86-64, release_tag: ""` (dev stamp) + `secrets: inherit`. Job `test` → `needs: build-x64`, `uses: ./.github/workflows/boot-ota-test.yml` with `expected_tag: dev`, `last_release_tag: ""` (PR path runs T1 only to keep it bounded; T2 is the release-gate's job), `new_artifact: yocto-image-qemux86-64`.
- [ ] **Step 2:** `ci.yml`: add a step to the `validate` job (or a new `l0a` job) that runs `scripts/l0a-fstab-uuid-lint.sh .`.
- [ ] **Step 3:** yamllint both → clean.
- [ ] **Step 4:** Commit — `git commit -m "ci: L0a on every PR + boot-critical PR boot/OTA test"`

---

## Task 11: Release rework — `workflow_dispatch` + compute-version + gate

**Files:**
- Modify: `.github/workflows/release.yml`, `scripts/release.sh`

- [ ] **Step 1:** Rework `release.yml`:
  - Trigger → `on: workflow_dispatch: inputs: { dry_run: {type: boolean, default: false} }`. Remove the tag-push trigger.
  - `checkout` gains `fetch-depth: 0` where the version is computed.
  - New job `version` (`needs: preflight`): uses `./.github/actions/compute-version` → output `version`.
  - `build-x64`/`build-rpi`: `needs: [preflight, version]`, `release_tag: ${{ needs.version.outputs.version }}`.
  - New job `gate`: `needs: [version, build-x64]`, `uses: ./.github/workflows/boot-ota-test.yml` with `expected_tag: ${{ needs.version.outputs.version }}`, `last_release_tag: <previous latest release>` (a small step: `gh release list -L1 --json tagName -q '.[0].tagName'`), `new_artifact: yocto-image-qemux86-64`.
  - `release` (publish): `needs: [build-x64, build-rpi, gate, version]`, `if: ${{ !inputs.dry_run }}`; add to `action-gh-release`: `tag_name: ${{ needs.version.outputs.version }}` + `target_commitish: ${{ github.sha }}`; replace all `${{ github.ref_name }}` with `${{ needs.version.outputs.version }}`. Add a default-branch guard for real (non-dry) runs (mirror FW lines 27-38).
  - `dry_run: true` → runs preflight+version+build+gate, skips cosign-sign + create-release.
- [ ] **Step 2:** Reduce `scripts/release.sh` to a thin dispatcher: `gh workflow run release.yml [-f dry_run=true]`, with a note that version is computed server-side. Keep `--dry-run` → `-f dry_run=true`.
- [ ] **Step 3:** yamllint `release.yml` → clean; shellcheck `release.sh`.
- [ ] **Step 4:** Commit — `git commit -m "ci(release): one-button dispatch + auto-version + boot/OTA publish gate"`

---

## Task 12: Feasibility spike workflow + README wiring

**Files:**
- Create: `.github/workflows/boot-ota-spike.yml`

- [ ] **Step 1:** `boot-ota-spike.yml`: `on: workflow_dispatch: inputs: { release_tag: {type: string, default: ""} }`. On `ubuntu-latest`: install qemu+ovmf; `gh release download` the given (or latest) release wic; time a headless TCG boot to `login:` (a tiny inline python/pexpect snippet or reuse `test_boot.py` with a no-update dummy); print wall-clock, `free -m`, and `df -h` (disk headroom). Purpose: decide GH-hosted vs Hetzner. Job `timeout-minutes: 45`.
- [ ] **Step 2:** yamllint → clean.
- [ ] **Step 3:** Update `tests/ota-integration/README.md` with the spike + how to flip `runner_label` to a self-hosted Hetzner label if the spike shows GH-hosted is insufficient.
- [ ] **Step 4:** Commit — `git commit -m "ci: TCG boot feasibility spike (GH-hosted vs Hetzner decision)"`

---

## Task 13: Self-verification notes + open final PR

**Files:**
- Modify: `tests/ota-integration/README.md`

- [ ] **Step 1:** Add a "Verification of the test itself" section to the README: how to prove the harness catches the known bugs — temporarily revert #37 (`--use-uuid`, drop `--no-fstab-update`) → L0a red, L0b red, T2 red (emergency/rollback); revert #36 (skip relabel) → T2 red. Document as the acceptance check for the harness (run in a throwaway branch, not on main).
- [ ] **Step 2:** Final self-review pass: `yamllint` all workflows, `shellcheck` the new shell scripts, `python -m pytest tests/ota-integration -m unit` green.
- [ ] **Step 3:** Commit — `git commit -m "docs(ota-it): harness self-verification guide"`
- [ ] **Step 4:** Push branch, open PR (do NOT merge — user reviews). PR body: summarize the harness, the two bugs it catches, the cadence (L0a every PR, T1 on boot-critical PRs, T1+T2 as release gate), the runner-feasibility open item, and what is CI-verified vs unit-verified locally.

---

## Self-Review (author checklist — completed at plan time)

- **Spec coverage:** dummy server (T2/Task2), Target interface incl. CM4 stub (Task4), config injection = seed (Task3), T1/T2/T3 (Tasks 5-6), L0a/L0b (Task7), reusable boot-ota-test + runner param (Task9), boot-critical PR + release gate + dispatch/auto-version (Tasks 10-11), feasibility spike (Task12), self-verification (Task13). ✓
- **Resolved open items folded in:** data-init preserves seeded config ✓; payload = extracted root_a ext4 bz2 ✓; plain http ok ✓; RPi console ✓ (CM4 stub only).
- **Type consistency:** `DummyOtaServer` fields (`heartbeats/status_updates/commits/downloads/offer_update/result_status/last_reported_version/url/port`), `Target` methods (`flash/seed_config/power_on/power_off/reset/console/dut_server_url/boot_markers/reset_ab_state`), and env vars (`OTA_IT_WIC/OTA_IT_LAST_RELEASE_WIC/OTA_IT_EXPECTED_TAG`) are used identically across tasks. ✓
- **CM4 = future:** only a `NotImplementedError` stub ships now (Task4); no bench code. ✓
