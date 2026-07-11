import os
import subprocess

import pytest

pytestmark = pytest.mark.unit

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_SCRIPT = os.path.join(_REPO, "scripts", "compute-release-version.sh")


def _run(now, existing):
    return subprocess.run(
        [_SCRIPT, "--now", now, "--existing", existing],
        capture_output=True, text=True, check=True,
    ).stdout.strip()


def test_base_when_no_existing():
    assert _run("2026.07.11-15", "") == "2026.07.11-15"


def test_first_suffix_when_base_taken():
    assert _run("2026.07.11-15", "2026.07.11-15") == "2026.07.11-15a"


def test_second_suffix_when_a_taken():
    assert _run("2026.07.11-15", "2026.07.11-15\n2026.07.11-15a") == "2026.07.11-15b"


def test_ignores_unrelated_tags():
    assert _run("2026.07.11-15", "2026.07.10-21\n2025.01.01-00") == "2026.07.11-15"
