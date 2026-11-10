"""Static + behaviour guards for the passive-service decoder host (Direwolf recipe,
`oe5xrx-decoder` user/template unit/wrapper). Spec 2026-11-10-passive-services-aprs-design
§5.2/§5.3/§9/§10. File-content checks plus running the wrapper with fake
pw-record/direwolf on PATH — `-m unit`, no build/qemu needed."""

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


# ---- wrapper ----------------------------------------------------------------

def test_wrapper_syntax():
    subprocess.run(["bash", "-n", _path(*_WRAPPER)], check=True)


def test_wrapper_has_no_eval():
    assert not any(re.search(r"\beval\b", ln) for ln in _code_lines(_read(*_WRAPPER)))


def _fakes(tmp_path, pw_exit=0):
    """Fake pw-record + direwolf first on PATH. direwolf copies its -c conf away
    and drops a marker; pw-record drops a marker too."""
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
    for f in bindir.iterdir():
        f.chmod(f.stat().st_mode | stat.S_IXUSR)
    return bindir


def _run(tmp_path, env_over=None, pw_exit=0, instance="aprs-slot1"):
    rundir = tmp_path / "run"
    rundir.mkdir(exist_ok=True)
    env = {
        "PATH": f"{_fakes(tmp_path, pw_exit)}:{os.environ['PATH']}",
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
    r = _run(tmp_path, {"OE5XRX_DECODER": "sstv"}, instance="sstv-slot1")
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
