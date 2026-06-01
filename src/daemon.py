#!/usr/bin/env python3
"""Vanguard telemetry daemon — simulates continuous vehicle telemetry with anomalies."""

from __future__ import annotations

import json
import logging
import os
import random
import signal
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any

from prometheus_client import Counter, Gauge, start_http_server
from pythonjsonlogger.json import JsonFormatter

# ---------------------------------------------------------------------------
# Configuration (override via environment variables)
# ---------------------------------------------------------------------------

INTERVAL_SECONDS = float(os.getenv("TELEMETRY_INTERVAL", "1.0"))
VEHICLE_IDS = os.getenv("VEHICLE_IDS", "VH-001,VH-002,VH-003,VH-004,VH-005").split(",")
SENSOR_STATUSES = ("ok", "degraded", "warning", "critical")

ANOMALY_CPU_SPIKE_PROB = float(os.getenv("ANOMALY_CPU_SPIKE_PROB", "0.02"))
ANOMALY_MEMORY_LEAK_PROB = float(os.getenv("ANOMALY_MEMORY_LEAK_PROB", "0.01"))
ANOMALY_CORRUPT_JSON_PROB = float(os.getenv("ANOMALY_CORRUPT_JSON_PROB", "0.015"))

CPU_SPIKE_DURATION_SECONDS = float(os.getenv("CPU_SPIKE_DURATION", "3.0"))
CPU_SPIKE_THREADS = int(os.getenv("CPU_SPIKE_THREADS", "4"))
MEMORY_LEAK_CHUNK_KB = int(os.getenv("MEMORY_LEAK_CHUNK_KB", "512"))

HEALTH_PORT = int(os.getenv("HEALTH_PORT", "8080"))
METRICS_PORT = int(os.getenv("METRICS_PORT", "8000"))

# ---------------------------------------------------------------------------
# Prometheus metrics
# ---------------------------------------------------------------------------

TELEMETRY_EMITTED = Counter(
    "vanguard_telemetry_emitted_total",
    "Total successful JSON telemetry packets emitted",
)

ANOMALIES_DETECTED = Counter(
    "vanguard_anomalies_detected_total",
    "Total production anomalies detected by type",
    labelnames=("anomaly_type",),
)

MEMORY_USAGE_BYTES = Gauge(
    "vanguard_memory_usage_bytes",
    "Simulated memory consumption retained by the daemon process",
)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logger = logging.getLogger("vanguard.telemetry")
_handler = logging.StreamHandler(sys.stdout)
_handler.setFormatter(JsonFormatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
logger.addHandler(_handler)
logger.setLevel(logging.INFO)

# ---------------------------------------------------------------------------
# Global state
# ---------------------------------------------------------------------------

_shutdown = threading.Event()
_memory_leak_buffer: list[bytes] = []
_stats_lock = threading.Lock()
_stats: dict[str, int] = {
    "telemetry_emitted": 0,
    "cpu_spikes": 0,
    "memory_leaks": 0,
    "corrupt_payloads": 0,
    "anomalies_total": 0,
}


def _increment_stat(key: str) -> None:
    with _stats_lock:
        _stats[key] += 1
        if key != "telemetry_emitted":
            _stats["anomalies_total"] += 1


def _record_anomaly(anomaly_type: str, stat_key: str) -> None:
    _increment_stat(stat_key)
    ANOMALIES_DETECTED.labels(anomaly_type=anomaly_type).inc()


def update_memory_gauge() -> None:
    simulated_bytes = sum(len(chunk) for chunk in _memory_leak_buffer)
    MEMORY_USAGE_BYTES.set(simulated_bytes)


# ---------------------------------------------------------------------------
# Anomaly simulators
# ---------------------------------------------------------------------------


def _cpu_spike_worker(stop: threading.Event) -> None:
    """Burn CPU in a tight loop until stop is set."""
    while not stop.is_set():
        _ = sum(i * i for i in range(10_000))


def trigger_cpu_spike() -> None:
    """Simulate a sudden multi-threaded CPU spike (~90% utilization)."""
    _record_anomaly("cpu_spike", "cpu_spikes")
    logger.warning(
        "anomaly_detected",
        extra={"anomaly_type": "cpu_spike", "threads": CPU_SPIKE_THREADS},
    )

    stop = threading.Event()
    threads = [
        threading.Thread(target=_cpu_spike_worker, args=(stop,), daemon=True)
        for _ in range(CPU_SPIKE_THREADS)
    ]
    for t in threads:
        t.start()

    time.sleep(CPU_SPIKE_DURATION_SECONDS)
    stop.set()
    for t in threads:
        t.join(timeout=1.0)


def trigger_memory_leak() -> None:
    """Append retained bytes to simulate a gradual memory leak."""
    chunk = os.urandom(MEMORY_LEAK_CHUNK_KB * 1024)
    _memory_leak_buffer.append(chunk)
    _record_anomaly("memory_leak", "memory_leaks")
    update_memory_gauge()
    logger.warning(
        "anomaly_detected",
        extra={
            "anomaly_type": "memory_leak",
            "chunks_retained": len(_memory_leak_buffer),
            "approx_leaked_mb": round(len(_memory_leak_buffer) * MEMORY_LEAK_CHUNK_KB / 1024, 2),
        },
    )


def emit_corrupt_payload() -> None:
    """Write malformed JSON directly to stdout (bypasses the logger)."""
    _record_anomaly("corrupt_json", "corrupt_payloads")
    vehicle_id = random.choice(VEHICLE_IDS)
    corrupt_variants = [
        f'{{"vehicle_id": "{vehicle_id}", "timestamp": "{datetime.now(timezone.utc).isoformat()}", '
        f'"speed": 62.5, "fuel_level": 45.2, "sensor_status": "ok"',  # missing closing brace
        f'{{vehicle_id: {vehicle_id}, speed: NaN, fuel_level: null}}',  # invalid JSON syntax
        '{"vehicle_id": "VH-???", "timestamp": "NOT-A-DATE", "speed": "fast", '
        '"fuel_level": -999, "sensor_status": 12345}',  # wrong types
        '{"vehicle_id": "' + vehicle_id + '", "data": "' + "A" * 2048 + '"}',  # truncated mid-stream
    ]
    payload = random.choice(corrupt_variants)
    sys.stdout.write(payload + "\n")
    sys.stdout.flush()
    logger.warning(
        "anomaly_detected",
        extra={"anomaly_type": "corrupt_json", "payload_preview": payload[:120]},
    )


# ---------------------------------------------------------------------------
# Telemetry generation
# ---------------------------------------------------------------------------


def build_telemetry_record() -> dict[str, Any]:
    return {
        "vehicle_id": random.choice(VEHICLE_IDS),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "speed": round(random.uniform(0, 130), 1),
        "fuel_level": round(random.uniform(5, 100), 1),
        "sensor_status": random.choices(
            SENSOR_STATUSES,
            weights=[85, 8, 5, 2],
            k=1,
        )[0],
    }


def maybe_trigger_anomaly() -> None:
    roll = random.random()
    if roll < ANOMALY_CORRUPT_JSON_PROB:
        emit_corrupt_payload()
        return
    if roll < ANOMALY_CORRUPT_JSON_PROB + ANOMALY_CPU_SPIKE_PROB:
        threading.Thread(target=trigger_cpu_spike, daemon=True).start()
        return
    if roll < ANOMALY_CORRUPT_JSON_PROB + ANOMALY_CPU_SPIKE_PROB + ANOMALY_MEMORY_LEAK_PROB:
        trigger_memory_leak()


def emit_telemetry() -> None:
    record = build_telemetry_record()
    _increment_stat("telemetry_emitted")
    TELEMETRY_EMITTED.inc()
    logger.info("telemetry", extra={"telemetry": record})


def telemetry_loop() -> None:
    logger.info(
        "daemon_started",
        extra={
            "interval_seconds": INTERVAL_SECONDS,
            "vehicle_count": len(VEHICLE_IDS),
            "health_port": HEALTH_PORT,
            "metrics_port": METRICS_PORT,
        },
    )
    update_memory_gauge()
    while not _shutdown.is_set():
        emit_telemetry()
        maybe_trigger_anomaly()
        update_memory_gauge()
        _shutdown.wait(timeout=INTERVAL_SECONDS)


# ---------------------------------------------------------------------------
# Health endpoint (for container orchestration / probes)
# ---------------------------------------------------------------------------


class _HealthHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/health", "/healthz", "/"):
            with _stats_lock:
                body = json.dumps({"status": "ok", "stats": dict(_stats)}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002
        return  # suppress default stderr access logs


def run_health_server() -> None:
    server = HTTPServer(("0.0.0.0", HEALTH_PORT), _HealthHandler)
    server.timeout = 1.0
    logger.info("health_server_listening", extra={"port": HEALTH_PORT})
    while not _shutdown.is_set():
        server.handle_request()
    server.server_close()


# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------


def _handle_signal(signum: int, _frame: Any) -> None:
    logger.info("shutdown_signal_received", extra={"signal": signum})
    _shutdown.set()


def main() -> int:
    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    start_http_server(METRICS_PORT)
    logger.info("metrics_server_listening", extra={"port": METRICS_PORT})

    health_thread = threading.Thread(target=run_health_server, daemon=True)
    health_thread.start()

    try:
        telemetry_loop()
    except Exception:
        logger.exception("daemon_crashed")
        return 1

    with _stats_lock:
        final_stats = dict(_stats)
    logger.info("daemon_stopped", extra={"final_stats": final_stats})
    return 0


if __name__ == "__main__":
    sys.exit(main())
