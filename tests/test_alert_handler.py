"""Tests for the automated alert handler."""

from __future__ import annotations

import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

SRC_DIR = Path(__file__).resolve().parents[1] / "src"
if str(SRC_DIR) not in sys.path:
    sys.path.insert(0, str(SRC_DIR))

import alert_handler  # noqa: E402


SAMPLE_METRICS = """
# HELP vanguard_memory_usage_bytes Simulated memory
# TYPE vanguard_memory_usage_bytes gauge
vanguard_memory_usage_bytes 16000000.0
# HELP vanguard_anomalies_detected_total Anomalies
# TYPE vanguard_anomalies_detected_total counter
vanguard_anomalies_detected_total{anomaly_type="corrupt_json"} 10.0
vanguard_anomalies_detected_total{anomaly_type="cpu_spike"} 2.0
"""


class TestAlertHandler:
    def test_parse_metrics_extracts_memory_and_corrupt_json(self) -> None:
        snapshot = alert_handler.parse_metrics(SAMPLE_METRICS)

        assert snapshot.memory_usage_bytes == 16_000_000.0
        assert snapshot.corrupt_json_total == 10.0

    def test_memory_threshold_breach_triggers_alert(self) -> None:
        snapshot = alert_handler.MetricsSnapshot(
            memory_usage_bytes=16_000_000.0,
            corrupt_json_total=0.0,
            fetched_at=datetime.now(timezone.utc),
            raw_metrics={},
        )
        evaluation = alert_handler.evaluate_thresholds(snapshot, None)

        assert evaluation.breached is True
        assert any("memory_usage" in reason for reason in evaluation.reasons)

    def test_corrupt_json_delta_breach_triggers_alert(self) -> None:
        previous = alert_handler.MetricsSnapshot(
            memory_usage_bytes=0.0,
            corrupt_json_total=2.0,
            fetched_at=datetime.now(timezone.utc),
            raw_metrics={},
        )
        current = alert_handler.MetricsSnapshot(
            memory_usage_bytes=0.0,
            corrupt_json_total=7.0,
            fetched_at=datetime.now(timezone.utc),
            raw_metrics={},
        )
        evaluation = alert_handler.evaluate_thresholds(current, previous)

        assert evaluation.breached is True
        assert any("corrupt_json" in reason for reason in evaluation.reasons)

    def test_healthy_metrics_do_not_breach(self) -> None:
        previous = alert_handler.MetricsSnapshot(
            memory_usage_bytes=1_000_000.0,
            corrupt_json_total=5.0,
            fetched_at=datetime.now(timezone.utc),
            raw_metrics={},
        )
        current = alert_handler.MetricsSnapshot(
            memory_usage_bytes=2_000_000.0,
            corrupt_json_total=6.0,
            fetched_at=datetime.now(timezone.utc),
            raw_metrics={},
        )
        evaluation = alert_handler.evaluate_thresholds(current, previous)

        assert evaluation.breached is False

    def test_critical_alert_report_contains_banner(self, capsys: pytest.CaptureFixture[str]) -> None:
        snapshot = alert_handler.MetricsSnapshot(
            memory_usage_bytes=20_000_000.0,
            corrupt_json_total=1.0,
            fetched_at=datetime.now(timezone.utc),
            raw_metrics={},
        )
        evaluation = alert_handler.evaluate_thresholds(snapshot, None)

        alert_handler.emit_critical_alert(evaluation, snapshot)
        output = capsys.readouterr().out

        assert "=== [CRITICAL ALERT] PIPELINE SLA BREACHED ===" in output
        assert "vanguard_memory_usage_bytes" in output
