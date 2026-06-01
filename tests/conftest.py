"""Shared pytest fixtures for Vanguard telemetry monitor tests."""

from __future__ import annotations

import sys
from collections.abc import Generator
from pathlib import Path

import pytest

# Make `src/` importable as top-level modules on all platforms (macOS, Linux, Windows).
SRC_DIR = Path(__file__).resolve().parents[1] / "src"
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

import daemon  # noqa: E402


@pytest.fixture(autouse=True)
def reset_daemon_state() -> Generator[None, None, None]:
    """Isolate tests by resetting in-process daemon counters and leak buffer."""
    with daemon._stats_lock:
        for key in daemon._stats:
            daemon._stats[key] = 0
    daemon._memory_leak_buffer.clear()
    daemon.update_memory_gauge()
    yield
    with daemon._stats_lock:
        for key in daemon._stats:
            daemon._stats[key] = 0
    daemon._memory_leak_buffer.clear()
    daemon.update_memory_gauge()
