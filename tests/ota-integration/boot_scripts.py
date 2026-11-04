"""Shared helpers for the two-stage CM4 U-Boot boot scripts.

`render_stage2` turns the stage-2 template (`boot-stage2.cmd.in`) into the
script text that is compiled to `/boot/boot-stage2.scr`. The u-boot-ab recipe
mirrors these exact rules with sed (keep both in sync); the sandbox tests
import this to render the same text the image ships.
"""

import os
import re

_REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
_FILES = os.path.join(_REPO, "meta-oe5xrx-remotestation", "recipes-bsp",
                      "u-boot-ab", "files")
STAGE1_CMD = os.path.join(_FILES, "boot.cmd")
STAGE2_TEMPLATE = os.path.join(_FILES, "boot-stage2.cmd.in")

_NAME_RE = re.compile(r"^[a-z0-9-]+$")

PH_OVERLAYS = "@OE5XRX_DT_OVERLAYS@"
PH_OVERLAYS_CSV = "@OE5XRX_DT_OVERLAYS_CSV@"
PH_OVERLAYS_BOOTARG = "@OE5XRX_OVERLAYS_BOOTARG@"


def read_stage1() -> str:
    with open(STAGE1_CMD) as f:
        return f.read()


def read_stage2_template() -> str:
    with open(STAGE2_TEMPLATE) as f:
        return f.read()


def render_stage2(template: str, overlays: list[str]) -> str:
    """Fill the three stage-2 placeholders for the given overlay names.

    - @OE5XRX_DT_OVERLAYS@      -> "a b"
    - @OE5XRX_DT_OVERLAYS_CSV@  -> "a,b"
    - @OE5XRX_OVERLAYS_BOOTARG@ -> " oe5xrx.overlays=ok:a,b" ("" if no overlays)

    Names must match [a-z0-9-]+ (they end up unquoted in a hush for-loop, in
    a file path and in the kernel cmdline), otherwise ValueError.
    """
    for name in overlays:
        if not isinstance(name, str) or not _NAME_RE.match(name):
            raise ValueError(f"invalid overlay name: {name!r} "
                             "(allowed: [a-z0-9-]+)")
    csv = ",".join(overlays)
    bootarg = f" oe5xrx.overlays=ok:{csv}" if overlays else ""
    return (template
            .replace(PH_OVERLAYS_BOOTARG, bootarg)
            .replace(PH_OVERLAYS_CSV, csv)
            .replace(PH_OVERLAYS, " ".join(overlays)))
