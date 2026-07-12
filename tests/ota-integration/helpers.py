"""Condition-based waiting — never fixed sleeps (TCG timing varies widely)."""

from __future__ import annotations

import time
from typing import Callable


def wait_until(predicate: Callable[[], bool], timeout: float, interval: float = 1.0) -> bool:
    """Poll `predicate` until it is truthy or `timeout` seconds elapse.
    Returns the final truthiness. Uses a monotonic clock."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()
