"""Static + behaviour guards for the passive-service decoder host (Direwolf recipe,
`oe5xrx-decoder` user/template unit/wrapper). Spec 2026-11-10-passive-services-aprs-design
§5.2/§5.3/§9/§10, SSTV (station-manager spec 2026-11-24-sstv-design, plan Task 15).
File-content checks plus running the wrapper with fake pw-record/direwolf/python3 on
PATH — `-m unit`, no build/qemu needed."""

import os
import re
import stat
import subprocess

import pytest

pytestmark = pytest.mark.unit

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_LAYER = "meta-oe5xrx-remotestation"
_DW = (_LAYER, "recipes-multimedia", "direwolf", "direwolf_1.8.1.bb")
_DEC = (_LAYER, "recipes-multimedia", "oe5xrx-decoder")
_RECIPE = _DEC + ("oe5xrx-decoder_1.0.bb",)
_UNIT = _DEC + ("files", "oe5xrx-decoder@.service")
_WRAPPER = _DEC + ("files", "oe5xrx-decoder-run")
_IMAGE = (_LAYER, "recipes-core", "images", "oe5xrx-remotestation-image.bb")
_AUDIO = (_LAYER, "recipes-multimedia", "oe5xrx-audio-system", "oe5xrx-audio-system_1.0.bb")
_AGENT = (_LAYER, "recipes-core", "station-agent", "station-agent_0.1.0.bb")
_SELFCHECK = ("tests", "audio", "audio_selfcheck.sh")


def _path(*parts):
    return os.path.join(_REPO, *parts)


def _read(*parts):
    with open(_path(*parts)) as f:
        return f.read()


def _code_lines(txt):
    """Non-comment, non-blank lines (BitBake/systemd/shell comments start with #)."""
    return [ln for ln in txt.splitlines()
            if ln.strip() and not ln.lstrip().startswith("#")]


def _directives(txt):
    """{key: value} of the unit's code lines (last value wins)."""
    out = {}
    for ln in _code_lines(txt):
        if "=" in ln and not ln.startswith("["):
            k, v = ln.split("=", 1)
            out[k.strip()] = v.strip()
    return out


# ---- Direwolf recipe ------------------------------------------------------

def test_direwolf_recipe_pinned():
    txt = "\n".join(_code_lines(_read(*_DW)))
    assert "AUTOREV" not in txt
    assert re.search(r'^SRCREV\s*=\s*"[0-9a-f]{40}"', txt, re.M)
    assert os.path.basename(_path(*_DW)) == "direwolf_1.8.1.bb"


def test_direwolf_recipe_minimal():
    lines = _code_lines(_read(*_DW))
    assert 'DEPENDS = "alsa-lib"' in [ln.strip() for ln in lines]
    # upstream installs the CM108 rule to /usr/lib/udev/rules.d (CI-proven)
    assert any("nonarch_libdir}/udev" in ln and "rm" in ln for ln in lines)
    assert 'FILES:${PN} = "${bindir}/direwolf"' in [ln.strip() for ln in lines]


def test_image_installs_direwolf_and_decoder():
    assert re.search(
        r'IMAGE_INSTALL:append\s*=\s*".*\bdirewolf\b.*\boe5xrx-decoder\b',
        _read(*_IMAGE))


# ---- oe5xrx-decoder recipe + unit -----------------------------------------

def test_unit_sandbox_and_log_limits():
    d = _directives(_read(*_UNIT))
    expected = {"User": "oe5xrx-decoder", "NoNewPrivileges": "yes",
                "ProtectSystem": "strict", "PrivateTmp": "yes",
                "LogLevelMax": "notice", "StandardOutput": "null",
                "Restart": "on-failure", "MemoryMax": "96M", "CPUQuota": "50%",
                "EnvironmentFile": "/run/oe5xrx/decoder/%i.env"}
    for k, v in expected.items():
        assert d[k] == v, k
    assert "LogRateLimitIntervalSec" in d and "LogRateLimitBurst" in d
    assert "StartLimitBurst" in d


def test_unit_network_sandbox():
    d = _directives(_read(*_UNIT))
    assert d["IPAddressDeny"] == "any" and d["IPAddressAllow"] == "localhost"


def test_unit_config_error_not_restarted_and_logged():
    d = _directives(_read(*_UNIT))
    assert d["RestartPreventExitStatus"] == "2"
    assert d["SyslogLevel"] == "notice"


def test_kernel_fragment_cgroup_bpf_in_both_kernels():
    cfg = _code_lines(_read(_LAYER, "recipes-kernel", "linux", "files",
                            "oe5xrx-cgroup-bpf.cfg"))
    assert "CONFIG_CGROUP_BPF=y" in [ln.strip() for ln in cfg]
    for bb in ("linux-yocto_%.bbappend", "linux-raspberrypi_%.bbappend"):
        assert "oe5xrx-cgroup-bpf.cfg" in _read(_LAYER, "recipes-kernel", "linux", bb)


def test_wrapper_error_is_journal_priority_err(tmp_path):
    r = _run(tmp_path, {"OE5XRX_RX_NODE": "a;b"})
    assert r.stderr.startswith("<3>")


def test_unit_coupled_to_agent():
    lines = [ln.strip() for ln in _code_lines(_read(*_UNIT))]
    for want in ("PartOf=station-agent.service", "BindsTo=station-agent.service",
                 "After=station-agent.service"):
        assert want in lines
    # agent starts instances itself: nothing may pull them in from the agent side
    assert not any(ln.startswith(("WantedBy=", "RequiredBy=")) for ln in lines)


def test_unit_template_not_enabled():
    recipe = _read(*_RECIPE)
    assert 'SYSTEMD_AUTO_ENABLE = "disable"' in recipe
    # the unit has no [Install]: nothing can enable it at boot
    assert "[Install]" not in _read(*_UNIT)


def test_decoder_user_in_pipewire_group():
    r = _read(*_RECIPE)
    assert "USERADD_DEPENDS" in r and "--groups pipewire" in r
    # rootfs install order: the package that creates group 'pipewire' must be a
    # runtime dependency (CI: "useradd: group 'pipewire' does not exist")
    rdeps = [ln for ln in _code_lines(r) if ln.startswith("RDEPENDS:${PN}")]
    assert rdeps and re.search(r"\bpipewire\b", rdeps[0])


def _rdepends(*recipe):
    """Package names of the recipe's RDEPENDS:${PN} (single- or multi-line)."""
    txt = "\n".join(_code_lines(_read(*recipe)))
    m = re.search(r'^RDEPENDS:\$\{PN\}\s*\+?=\s*"([^"]*)"', txt, re.M)
    assert m, recipe
    return set(m.group(1).replace("\\", " ").split())


def test_decoder_rdepends_sstv_runtime():
    # rx_unit imports numpy; the module itself ships in station-agent.
    assert {"python3-numpy", "station-agent"} <= _rdepends(*_RECIPE)


# Elements of the agent's SSTV TX player (station_agent/sstv_tx.py build_play_argv)
# -> the split package that ships each. The '-base' top package is empty and only
# RRECOMMENDS '-meta', so every element needs its split package pinned.
_SSTV_TX_ELEMENTS = {
    "rawaudioparse": "gstreamer1.0-plugins-base-rawparse",
    "audioconvert": "gstreamer1.0-plugins-base-audioconvert",
    "audioresample": "gstreamer1.0-plugins-base-audioresample",
    "volume": "gstreamer1.0-plugins-base-volume",
    "pipewiresink": "gstreamer1.0-pipewire",
    "filesrc": "gstreamer1.0",  # coreelements; also ships gst-launch-1.0
}


@pytest.mark.parametrize("element", sorted(_SSTV_TX_ELEMENTS))
def test_sstv_tx_gst_element_installed(element):
    assert _SSTV_TX_ELEMENTS[element] in _rdepends(*_AUDIO)


def test_audio_rdepends_lint_covers_sstv_tx():
    lint = _read("scripts", "l3-audio-rdepends-lint.sh")
    for pkg in _SSTV_TX_ELEMENTS.values():
        if pkg != "gstreamer1.0":
            assert pkg in lint, pkg


def test_qemu_selfcheck_covers_sstv():
    txt = "\n".join(_code_lines(_read(*_SELFCHECK)))
    loop = re.search(r"for el in (.*?); do", txt, re.S).group(1)
    for el in ("rawaudioparse", "volume", "audioconvert", "audioresample", "pipewiresink"):
        assert re.search(rf"\b{el}\b", loop), el
    # the real module, under the sandbox parsed from the installed unit file
    assert "oe5xrx-decoder@.service" in txt
    assert re.search(r'systemd-run[^\n]*"\$@"', txt)
    assert "python3 -I -m station_agent.sstv.rx_unit --port 8299 --rate 8000 </dev/null" in txt


# [Service] keys of the unit that are not sandbox/identity/limits (lifecycle,
# logging, the env file) and so are not mirrored by the QEMU rx_unit check.
_NON_SANDBOX_KEYS = {
    "Type", "EnvironmentFile", "RuntimeDirectory", "ExecStart", "Restart",
    "RestartSec", "RestartPreventExitStatus", "StandardOutput", "StandardError",
    "LogLevelMax", "SyslogLevel", "LogRateLimitIntervalSec", "LogRateLimitBurst",
}


def _selfcheck_sandbox_patterns():
    sc = _read(*_SELFCHECK)
    case = re.search(r'case "\$line" in\n(.*?)\)\n\s*set -- "\$@" -p', sc, re.S).group(1)
    case = re.sub(r"#[^\n]*", "", case).replace("\\\n", "")
    return [p.strip() for p in case.split("|")]


def test_selfcheck_mirrors_every_unit_sandbox_key():
    import fnmatch
    pats = _selfcheck_sandbox_patterns()
    unit = _read(*_UNIT)
    keys = {ln.split("=", 1)[0].strip() for ln in _code_lines(unit[unit.index("[Service]"):])
            if "=" in ln and not ln.startswith("[")}
    sandbox = keys - _NON_SANDBOX_KEYS
    assert len(sandbox) >= 20
    for k in sorted(sandbox):
        assert any(fnmatch.fnmatchcase(f"{k}=x", p) for p in pats), k
    for k in sorted(keys & _NON_SANDBOX_KEYS):
        assert not any(fnmatch.fnmatchcase(f"{k}=x", p) for p in pats), k


def test_station_agent_pinned():
    txt = "\n".join(_code_lines(_read(*_AGENT)))
    assert "AUTOREV" not in txt
    assert re.search(r'^SRCREV\s*=\s*"[0-9a-f]{40}"', txt, re.M)


# ---- wrapper ----------------------------------------------------------------

def test_wrapper_syntax():
    subprocess.run(["bash", "-n", _path(*_WRAPPER)], check=True)


def test_wrapper_has_no_eval():
    assert not any(re.search(r"\beval\b", ln) for ln in _code_lines(_read(*_WRAPPER)))


def _fakes(tmp_path, pw_exit=0, py_exit=0):
    """Fake pw-record + direwolf + python3 first on PATH. direwolf copies its -c
    conf away and drops a marker; pw-record and python3 record their args."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    (bindir / "pw-record").write_text(
        f"#!/bin/bash\ntouch '{tmp_path}/pw-called'\n"
        f"printf '%s\\n' \"$@\" >'{tmp_path}/pw-args'\nexit {pw_exit}\n")
    (bindir / "direwolf").write_text(
        "#!/bin/bash\n"
        f"touch '{tmp_path}/dw-called'\n"
        'while [ $# -gt 0 ]; do [ "$1" = -c ] && cp "$2" '
        f"'{tmp_path}/conf.out'; shift; done\n"
        "cat >/dev/null\nexit 0\n")
    (bindir / "python3").write_text(
        f"#!/bin/bash\ntouch '{tmp_path}/py-called'\n"
        f"printf '%s\\n' \"$@\" >'{tmp_path}/py-args'\n"
        f"cat >/dev/null\nexit {py_exit}\n")
    for f in bindir.iterdir():
        f.chmod(f.stat().st_mode | stat.S_IXUSR)
    return bindir


def _run(tmp_path, env_over=None, pw_exit=0, instance="aprs-slot1", py_exit=0):
    rundir = tmp_path / "run"
    rundir.mkdir(exist_ok=True)
    env = {
        "PATH": f"{_fakes(tmp_path, pw_exit, py_exit)}:{os.environ['PATH']}",
        "OE5XRX_DECODER": "aprs", "OE5XRX_SLOT": "1",
        "OE5XRX_RX_NODE": "oe5xrx.slot1", "OE5XRX_KISS_PORT": "8101",
        "OE5XRX_SAMPLE_RATE": "48000", "OE5XRX_TEST_RUNDIR": str(rundir),
    }
    env.update(env_over or {})
    return subprocess.run(["bash", _path(*_WRAPPER), instance], env=env,
                          capture_output=True, text=True, timeout=30)


def test_wrapper_writes_rx_only_conf(tmp_path):
    r = _run(tmp_path)
    assert r.returncode == 1, r.stderr  # clean pipeline exit is reported as failure
    conf = (tmp_path / "conf.out").read_text()
    for want in ("ADEVICE stdin null", "KISSPORT 8101", "AGWPORT 0", "ARATE 48000"):
        assert want in conf
    for bad in ("PTT", "BEACON", "IGSERVER", "DIGIPEAT"):
        assert bad not in conf


@pytest.mark.parametrize("bad", ["node\nKISSPORT 1", "a;b", "$(id)", "a b", ""])
def test_wrapper_rejects_bad_node(tmp_path, bad):
    r = _run(tmp_path, {"OE5XRX_RX_NODE": bad})
    assert r.returncode == 2
    assert not (tmp_path / "pw-called").exists()
    assert not (tmp_path / "dw-called").exists()


@pytest.mark.parametrize("over", [
    {"OE5XRX_KISS_PORT": "80"}, {"OE5XRX_KISS_PORT": "99999"},
    {"OE5XRX_KISS_PORT": "81x1"}, {"OE5XRX_SAMPLE_RATE": "48000;id"},
    {"OE5XRX_SAMPLE_RATE": "0000"}, {"OE5XRX_SAMPLE_RATE": "999999"},
    {"OE5XRX_DECODER": "sstv"}, {"OE5XRX_SLOT": "2"},
])
def test_wrapper_rejects_bad_env(tmp_path, over):
    r = _run(tmp_path, over)
    assert r.returncode == 2
    assert not (tmp_path / "dw-called").exists()


def test_wrapper_rejects_bad_instance(tmp_path):
    assert _run(tmp_path, instance="../x").returncode == 2


def test_wrapper_unknown_decoder(tmp_path):
    r = _run(tmp_path, {"OE5XRX_DECODER": "foo"}, instance="foo-slot1")
    assert r.returncode == 2
    assert not (tmp_path / "pw-called").exists()


def test_wrapper_pw_record_raw_and_no_fallback(tmp_path):
    _run(tmp_path)
    args = (tmp_path / "pw-args").read_text().splitlines()
    assert "--raw" in args  # no AU header in front of the samples
    # missing node must fail instead of falling back to the default source
    props = args[args.index("-P") + 1]
    assert "node.dont-fallback=true" in props and "node.dont-reconnect=true" in props
    assert args[args.index("--target") + 1] == "oe5xrx.slot1"
    assert args[-1] == "-"  # stdout


def test_wrapper_clean_pipeline_exit_is_failure(tmp_path):
    # pw-record + direwolf both exit 0 -> still non-zero so Restart=on-failure fires
    r = _run(tmp_path, pw_exit=0)
    assert r.returncode == 1
    assert "pipeline ended unexpectedly" in r.stderr


def test_wrapper_pipeline_failure_propagates(tmp_path):
    assert _run(tmp_path, pw_exit=1).returncode != 0


# ---- wrapper: sstv ----------------------------------------------------------

def _run_sstv(tmp_path, env_over=None, slot=1, **kw):
    """Env exactly as station_agent/decoders/sstv.py writes it (no KISS port,
    port = 8200 + slot, 8 kHz) — the aprs-only keys are removed."""
    env = {"OE5XRX_DECODER": "sstv", "OE5XRX_SLOT": str(slot),
           "OE5XRX_RX_NODE": f"oe5xrx.slot{slot}",
           "OE5XRX_SSTV_PORT": str(8200 + slot), "OE5XRX_SAMPLE_RATE": "8000",
           "OE5XRX_KISS_PORT": None, "OE5XRX_TEST_RUNDIR": None}
    env.update(env_over or {})
    rundir = tmp_path / "run"
    rundir.mkdir(exist_ok=True)
    full = {"PATH": f"{_fakes(tmp_path, kw.get('pw_exit', 0), kw.get('py_exit', 0))}"
                    f":{os.environ['PATH']}"}
    full.update({k: v for k, v in env.items() if v is not None})
    return subprocess.run(["bash", _path(*_WRAPPER), f"sstv-slot{slot}"], env=full,
                          capture_output=True, text=True, timeout=30)


def test_wrapper_sstv_runs_rx_unit(tmp_path):
    r = _run_sstv(tmp_path, slot=3)
    assert r.returncode == 1, r.stderr  # clean pipeline exit is reported as failure
    assert "pipeline ended unexpectedly" in r.stderr
    py = (tmp_path / "py-args").read_text().splitlines()
    assert py == ["-I", "-m", "station_agent.sstv.rx_unit",
                  "--port", "8203", "--rate", "8000"]
    assert not (tmp_path / "dw-called").exists()


def test_wrapper_sstv_pw_record_raw_and_no_fallback(tmp_path):
    _run_sstv(tmp_path, slot=2)
    args = (tmp_path / "pw-args").read_text().splitlines()
    assert "--raw" in args
    props = args[args.index("-P") + 1]
    assert "node.dont-fallback=true" in props and "node.dont-reconnect=true" in props
    assert args[args.index("--target") + 1] == "oe5xrx.slot2"
    assert args[args.index("--rate") + 1] == "8000"
    assert args[args.index("--channels") + 1] == "1"
    assert args[args.index("--format") + 1] == "s16"
    assert args[-1] == "-"


@pytest.mark.parametrize("over", [
    {"OE5XRX_SSTV_PORT": None}, {"OE5XRX_SSTV_PORT": ""},
    {"OE5XRX_SSTV_PORT": "8199"}, {"OE5XRX_SSTV_PORT": "8300"},
    {"OE5XRX_SSTV_PORT": "82a1"}, {"OE5XRX_SSTV_PORT": "8201;id"},
    {"OE5XRX_SSTV_PORT": "08201"}, {"OE5XRX_SSTV_PORT": "8202"},  # slot 1 -> 8201
    {"OE5XRX_SSTV_PORT": " 8201"}, {"OE5XRX_SSTV_PORT": "8201\n"},
    {"OE5XRX_SAMPLE_RATE": "8000;id"}, {"OE5XRX_RX_NODE": "$(id)"},
    {"OE5XRX_SLOT": "2"},
])
def test_wrapper_sstv_rejects_bad_env(tmp_path, over):
    r = _run_sstv(tmp_path, over)
    assert r.returncode == 2, r.stderr
    assert r.stderr.startswith("<3>")
    assert not (tmp_path / "pw-called").exists()
    assert not (tmp_path / "py-called").exists()


def test_wrapper_sstv_ignores_kiss_port(tmp_path):
    # the aprs key has no meaning for sstv and must not be needed or used
    r = _run_sstv(tmp_path, {"OE5XRX_KISS_PORT": "garbage"})
    assert r.returncode == 1, r.stderr
    assert "--port\n8201\n" in (tmp_path / "py-args").read_text()


def test_wrapper_sstv_rx_unit_failure_propagates(tmp_path):
    r = _run_sstv(tmp_path, py_exit=3)
    assert r.returncode == 3
    assert "pipeline ended unexpectedly" not in r.stderr


def test_wrapper_sstv_pw_record_failure_propagates(tmp_path):
    # pipefail: pw-record's own code, not the clean-end fallback (also 1)
    r = _run_sstv(tmp_path, pw_exit=3)
    assert r.returncode == 3
    assert "pipeline ended unexpectedly" not in r.stderr
