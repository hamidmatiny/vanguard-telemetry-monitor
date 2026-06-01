"""Unit tests for the Vanguard telemetry daemon."""

from __future__ import annotations

import json
import re
import threading
import urllib.error
import urllib.request
from http.server import HTTPServer
from typing import Any

import daemon
import pytest

REQUIRED_TELEMETRY_FIELDS = ("vehicle_id", "timestamp", "speed", "fuel_level", "sensor_status")
VALID_SENSOR_STATUSES = set(daemon.SENSOR_STATUSES)


class TestTelemetrySchema:
    """Validate telemetry record structure and JSON serializability."""

    def test_build_telemetry_record_contains_required_fields(self) -> None:
        record = daemon.build_telemetry_record()

        for field in REQUIRED_TELEMETRY_FIELDS:
            assert field in record, f"Missing required field: {field}"

    def test_build_telemetry_record_field_types_and_ranges(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(daemon, "VEHICLE_IDS", ["VH-UNIT-TEST"])

        record = daemon.build_telemetry_record()

        assert record["vehicle_id"] == "VH-UNIT-TEST"
        assert isinstance(record["timestamp"], str)
        assert re.match(r"^\d{4}-\d{2}-\d{2}T", record["timestamp"])
        assert isinstance(record["speed"], float)
        assert 0 <= record["speed"] <= 130
        assert isinstance(record["fuel_level"], float)
        assert 5 <= record["fuel_level"] <= 100
        assert record["sensor_status"] in VALID_SENSOR_STATUSES

    def test_telemetry_record_is_valid_json(self) -> None:
        record = daemon.build_telemetry_record()
        serialized = json.dumps(record)
        parsed = json.loads(serialized)

        assert parsed == record

    def test_emit_telemetry_increments_counter(self) -> None:
        before = daemon._stats["telemetry_emitted"]
        daemon.emit_telemetry()
        assert daemon._stats["telemetry_emitted"] == before + 1


class TestAnomalyInjection:
    """Validate anomaly simulators update error-tracking state."""

    def test_trigger_memory_leak_increments_stats_and_memory_gauge(self) -> None:
        before_leaks = daemon._stats["memory_leaks"]
        before_anomalies = daemon._stats["anomalies_total"]

        daemon.trigger_memory_leak()

        assert daemon._stats["memory_leaks"] == before_leaks + 1
        assert daemon._stats["anomalies_total"] == before_anomalies + 1
        assert len(daemon._memory_leak_buffer) == 1
        assert daemon.MEMORY_USAGE_BYTES._value.get() > 0  # noqa: SLF001

    def test_emit_corrupt_payload_increments_stats(self, capsys: pytest.CaptureFixture[str]) -> None:
        before = daemon._stats["corrupt_payloads"]
        before_anomalies = daemon._stats["anomalies_total"]

        daemon.emit_corrupt_payload()
        captured = capsys.readouterr()

        assert daemon._stats["corrupt_payloads"] == before + 1
        assert daemon._stats["anomalies_total"] == before_anomalies + 1
        assert captured.out.strip()  # corrupt payload written to stdout

    def test_trigger_cpu_spike_increments_stats(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(daemon, "CPU_SPIKE_DURATION_SECONDS", 0.01)
        monkeypatch.setattr(daemon, "CPU_SPIKE_THREADS", 1)

        before = daemon._stats["cpu_spikes"]
        before_anomalies = daemon._stats["anomalies_total"]

        daemon.trigger_cpu_spike()

        assert daemon._stats["cpu_spikes"] == before + 1
        assert daemon._stats["anomalies_total"] == before_anomalies + 1

    def test_record_anomaly_updates_prometheus_counter(self) -> None:
        before = daemon.ANOMALIES_DETECTED.labels(anomaly_type="cpu_spike")._value.get()  # noqa: SLF001

        daemon._record_anomaly("cpu_spike", "cpu_spikes")

        after = daemon.ANOMALIES_DETECTED.labels(anomaly_type="cpu_spike")._value.get()  # noqa: SLF001
        assert after == before + 1


class TestHealthServer:
    """Validate health endpoint behavior via HTTP client."""

    @staticmethod
    def _request_health(path: str = "/health") -> tuple[int, dict[str, Any]]:
        server = HTTPServer(("127.0.0.1", 0), daemon._HealthHandler)
        host, port = server.server_address

        thread = threading.Thread(
            target=lambda: (server.handle_request(), server.server_close()),
            daemon=True,
        )
        thread.start()
        thread.join(timeout=5)

        url = f"http://{host}:{port}{path}"
        with urllib.request.urlopen(url, timeout=5) as response:
            body = json.loads(response.read().decode())
            return response.status, body

    def test_health_endpoint_returns_200_and_ok_status(self) -> None:
        status_code, payload = self._request_health("/health")

        assert status_code == 200
        assert payload["status"] == "ok"
        assert isinstance(payload["stats"], dict)
        assert "telemetry_emitted" in payload["stats"]

    def test_healthz_and_root_paths_return_ok(self) -> None:
        for path in ("/healthz", "/"):
            status_code, payload = self._request_health(path)
            assert status_code == 200
            assert payload["status"] == "ok"

    def test_unknown_path_returns_404(self) -> None:
        server = HTTPServer(("127.0.0.1", 0), daemon._HealthHandler)
        host, port = server.server_address

        thread = threading.Thread(
            target=lambda: (server.handle_request(), server.server_close()),
            daemon=True,
        )
        thread.start()
        thread.join(timeout=5)

        url = f"http://{host}:{port}/unknown"
        with pytest.raises(urllib.error.HTTPError) as exc_info:
            urllib.request.urlopen(url, timeout=5)

        assert exc_info.value.code == 404
