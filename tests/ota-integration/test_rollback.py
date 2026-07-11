"""T3 — rollback safety net (FOLLOW-UP, skipped by default).

The spec lists T3 as a follow-up. A deterministic, fast rollback under TCG is
non-trivial: an unbootable slot B either hangs (no auto-reboot → no bootcount
progression → no rollback, the very emergency-mode failure we fixed) or relies
on `panic=5` reboots to exhaust bootlimit — timing-sensitive under emulation.
The clean approaches are (a) inject a health-check failure so the agent itself
reports `rolled_back`, or (b) a hardware watchdog on the CM4 bench.

This test documents the intended shape; enable it once one of those mechanisms
is wired (and consider bootlimit=1 to speed the trial). Until then it is
skipped so the suite never falsely claims rollback coverage.
"""

import pytest

pytestmark = pytest.mark.qemu


@pytest.mark.skip(reason="T3 rollback: follow-up — needs health-fail injection or watchdog (see docstring + spec)")
def test_t3_broken_slot_b_rolls_back(qemu_target, dummy_factory, last_release_wic, expected_tag):
    # Intended shape:
    #   payload = a deliberately broken rootfs (or withhold commit + bootlimit=1)
    #   flash last_release (slot A), reset_ab_state(bootlimit=1)
    #   offer the broken update; boot; after the trial fails, GRUB reverts to A
    #   assert: banner shows the OLD tag AND the agent reports 'rolled_back'
    raise NotImplementedError
