"""Device-under-test abstraction.

Test logic is written once against `Target`; only device-specific mechanics
(flash / seed / power / console / where the DUT reaches the dummy server /
boot markers) differ. `QemuTarget` is implemented now; `Cm4Target` is a stub
whose shape is fixed so the CM4 HIL bench is a drop-in, not a rewrite. See
docs/superpowers/specs/2026-07-11-boot-ota-integration-test-design.md.
"""

from __future__ import annotations

import os
import re
import select
import shutil
import socket
import subprocess
import tempfile
import time
from abc import ABC, abstractmethod

import image_ops
import seed

# OVMF firmware probe order (matches scripts/run-qemu.sh).
_OVMF_CODE_CANDIDATES = [
    "/usr/share/OVMF/OVMF_CODE_4M.fd",
    "/usr/share/OVMF/OVMF_CODE.fd",
    "/usr/share/edk2-ovmf/x64/OVMF_CODE.fd",
    "/usr/share/edk2/ovmf/OVMF_CODE.fd",
]
_OVMF_VARS_CANDIDATES = [
    "/usr/share/OVMF/OVMF_VARS_4M.fd",
    "/usr/share/OVMF/OVMF_VARS.fd",
    "/usr/share/edk2-ovmf/x64/OVMF_VARS.fd",
    "/usr/share/edk2/ovmf/OVMF_VARS.fd",
]

_PTS_RE = re.compile(r"char device redirected to (/dev/pts/\d+)")


def _free_port() -> int:
    s = socket.socket()
    s.bind(("", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _first_existing(paths):
    for p in paths:
        if os.path.exists(p):
            return p
    return None


class Target(ABC):
    @abstractmethod
    def flash(self, wic_path: str) -> None: ...
    @abstractmethod
    def seed_config(self, config_yaml: str, key_pem_path: str) -> None: ...
    @abstractmethod
    def reset_ab_state(self) -> None: ...
    @abstractmethod
    def power_on(self): ...
    @abstractmethod
    def power_off(self) -> None: ...
    @abstractmethod
    def reset(self) -> None: ...
    @abstractmethod
    def console(self): ...
    @abstractmethod
    def dut_server_url(self, dummy_port: int) -> str: ...

    def boot_markers(self) -> dict:
        # /etc/issue banner (carries the version) then the login prompt.
        # Capture only the tag charset ([A-Za-z0-9._-], enforced by stamp_release)
        # — NOT \S+, which would swallow trailing ANSI escapes (e.g. "dev\x1b[0m")
        # the console emits and break the exact version match.
        # The trailing (?=[^A-Za-z0-9._-]) lookahead REQUIRES a non-tag terminator
        # (ANSI ESC / CR / LF) after the tag, so pexpect can't match on a partial
        # tag that has only half-streamed over the serial console (which truncated
        # e.g. "2026.07.21-22" to "20" / "2026.07.2" and failed the exact match).
        return {"banner_re": r"OE5XRX Remote Station ([A-Za-z0-9._-]+)(?=[^A-Za-z0-9._-])",
                "login_re": r"login:"}


class QemuTarget(Target):
    def __init__(self, work_dir: str | None = None, mem: int = 1024, cpus: int = 2):
        self.work_dir = work_dir or tempfile.mkdtemp(prefix="ota-it-qemu-")
        self.mem = mem
        self.cpus = cpus
        self.ssh_port = _free_port()
        self.disk = os.path.join(self.work_dir, "disk.wic")
        self._proc: subprocess.Popen | None = None
        self._console = None

    # -- provisioning ------------------------------------------------------
    def flash(self, wic_path: str) -> None:
        image_ops.decompress_wic(wic_path, self.disk)

    def seed_config(self, config_yaml: str, key_pem_path: str) -> None:
        seed.seed_data_partition(self.disk, config_yaml, key_pem_path)

    def reset_ab_state(self) -> None:
        """Force the ESP grubenv to the committed slot-A default. The freshly
        flashed image already ships this default, so a missing grub-editenv is
        a warning, not a failure."""
        if not shutil.which("grub-editenv"):
            print("reset_ab_state: grub-editenv not found; relying on the "
                  "image's seeded committed-slot-A grubenv")
            return
        with seed._mount_partition(self.disk, image_ops.EFI_PARTNUM) as mnt:
            grubenv = os.path.join(mnt, "EFI/BOOT/grubenv")
            subprocess.run(
                ["grub-editenv", grubenv, "set",
                 "boot_part=a", "bootcount=0", "upgrade_available=0", "bootlimit=3"],
                check=True,
            )

    # -- power / console ---------------------------------------------------
    def power_on(self):
        import pexpect.fdpexpect

        ovmf_code = _first_existing(_OVMF_CODE_CANDIDATES)
        if not ovmf_code:
            raise RuntimeError("OVMF_CODE firmware not found; install the 'ovmf' package")
        vars_tpl = _first_existing(_OVMF_VARS_CANDIDATES)
        if not vars_tpl:
            raise RuntimeError("OVMF_VARS template not found; install the 'ovmf' package")
        ovmf_vars = os.path.join(self.work_dir, "OVMF_VARS.fd")
        shutil.copyfile(vars_tpl, ovmf_vars)

        cmd = ["qemu-system-x86_64", "-cpu", "IvyBridge", "-machine", "q35",
               "-m", str(self.mem), "-smp", str(self.cpus),
               "-display", "none", "-monitor", "none", "-serial", "pty"]
        if os.access("/dev/kvm", os.R_OK | os.W_OK):
            cmd.insert(1, "-enable-kvm")
        cmd += [
            "-drive", f"if=pflash,format=raw,readonly=on,file={ovmf_code}",
            "-drive", f"if=pflash,format=raw,file={ovmf_vars}",
            "-drive", f"file={self.disk},if=virtio,format=raw",
            "-device", "virtio-net-pci,netdev=n0",
            "-netdev", f"user,id=n0,hostfwd=tcp::{self.ssh_port}-:22",
        ]
        self._proc = subprocess.Popen(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        )
        # Discover the serial pty QEMU allocated. readline() on the pipe blocks,
        # so bound the discovery with a deadline via select() — otherwise a QEMU
        # that never prints the line (bad args, crash) would hang the test.
        pts = None
        deadline = time.monotonic() + 60
        stdout = self._proc.stdout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([stdout], [], [], 1.0)
            if not ready:
                continue
            line = stdout.readline()
            if not line:
                break
            m = _PTS_RE.search(line)
            if m:
                pts = m.group(1)
                break
        if not pts:
            self.power_off()
            raise RuntimeError("could not determine QEMU serial pty within 60s")
        fd = os.open(pts, os.O_RDWR | os.O_NOCTTY)
        self._console = pexpect.fdpexpect.fdspawn(fd, timeout=900, encoding="utf-8")
        return self._console

    def console(self):
        return self._console

    def power_off(self) -> None:
        # Close the console first so the underlying pty FD is not leaked across
        # resets / long CI runs.
        if self._console is not None:
            try:
                self._console.close()
            except Exception:
                pass
            self._console = None
        if self._proc is not None:
            self._proc.terminate()
            try:
                self._proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self._proc.kill()
            self._proc = None

    def reset(self) -> None:
        """Hard power-cycle: on QEMU, kill + relaunch (fresh boot of the same
        disk, preserving on-disk grubenv/A-B state). Read the fresh console via
        console() afterwards."""
        self.power_off()
        self.power_on()

    def dut_server_url(self, dummy_port: int) -> str:
        return f"http://10.0.2.2:{dummy_port}"


class Cm4Target(Target):
    """CM4 HIL bench — FUTURE WORK. See the spec's "CM4 HIL bench" section.

    Mechanics (not implemented): flash via rpiboot or SD (mux-less/SDWire),
    console via UART /dev/ttyUSB0, power via a controllable PDU/relay, DUT
    reaches the dummy at the bench host's LAN IP, u-boot boot markers.
    """

    _MSG = "CM4 bench is future work — see docs/superpowers/specs/2026-07-11-boot-ota-integration-test-design.md"

    def flash(self, wic_path: str) -> None: raise NotImplementedError(self._MSG)
    def seed_config(self, c, k) -> None: raise NotImplementedError(self._MSG)
    def reset_ab_state(self) -> None: raise NotImplementedError(self._MSG)
    def power_on(self): raise NotImplementedError(self._MSG)
    def power_off(self) -> None: raise NotImplementedError(self._MSG)
    def reset(self): raise NotImplementedError(self._MSG)
    def console(self): raise NotImplementedError(self._MSG)

    def dut_server_url(self, dummy_port: int) -> str:
        raise NotImplementedError(self._MSG)

    def boot_markers(self) -> dict:
        # u-boot prints a slot/attempt marker before the kernel + getty banner.
        # Trailing lookahead requires a non-tag terminator so a half-streamed tag
        # can't match early (see QemuTarget.boot_markers for the full rationale).
        return {"banner_re": r"OE5XRX Remote Station ([A-Za-z0-9._-]+)(?=[^A-Za-z0-9._-])",
                "login_re": r"login:",
                "uboot_re": r"OE5XRX: slot=(\w+) attempt=(\d+)/(\d+)"}
