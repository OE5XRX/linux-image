import os
import subprocess

import pytest

pytestmark = pytest.mark.unit

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_LINT = os.path.join(_REPO, "scripts", "l0a-fstab-uuid-lint.sh")


def _run(root):
    return subprocess.run([_LINT, root], capture_output=True, text=True)


def _wks(tmp_path, line):
    d = tmp_path / "meta-x" / "wic"
    d.mkdir(parents=True)
    (d / "test.wks.in").write_text(
        "bootloader --ptable=gpt\n" + line + "\n"
    )
    return str(tmp_path)


def test_flags_use_uuid_without_no_fstab_update(tmp_path):
    root = _wks(tmp_path, "part /boot --source bootimg-efi --fstype=vfat --label efi --use-uuid")
    r = _run(root)
    assert r.returncode != 0
    assert "--use-uuid without --no-fstab-update" in r.stdout


def test_passes_with_no_fstab_update(tmp_path):
    root = _wks(tmp_path, "part /boot --source bootimg-efi --fstype=vfat --label efi --use-uuid --no-fstab-update")
    r = _run(root)
    assert r.returncode == 0, r.stdout + r.stderr


def test_passes_for_non_mountpoint_part(tmp_path):
    root = _wks(tmp_path, "part --ondisk vda --fstype=ext4 --label root_b --use-uuid")
    r = _run(root)
    assert r.returncode == 0, r.stdout + r.stderr


def test_current_repo_is_clean():
    # The #37 fix already added --no-fstab-update to the real x64 wks.
    r = _run(_REPO)
    assert r.returncode == 0, r.stdout + r.stderr
