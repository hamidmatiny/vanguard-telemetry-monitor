#!/usr/bin/env python3
"""Automated incident controller — monitors Prometheus metrics and fires SLA alerts."""

from __future__ import annotations

import argparse
import os
import re
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

METRICS_URL = os.getenv("METRICS_URL", "http://127.0.0.1:8000/metrics")
POLL_INTERVAL_SECONDS = float(os.getenv("ALERT_POLL_INTERVAL", "10"))
FETCH_TIMEOUT_SECONDS = float(os.getenv("ALERT_FETCH_TIMEOUT", "5"))

MEMORY_THRESHOLD_BYTES = int(os.getenv("MEMORY_ALERT_THRESHOLD_BYTES", "15000000"))
CORRUPT_JSON_DELTA_THRESHOLD = int(os.getenv("CORRUPT_JSON_DELTA_THRESHOLD", "3"))

METRIC_MEMORY = "vanguard_memory_usage_bytes"
METRIC_CORRUPT_JSON = "vanguard_anomalies_detected_total"
CORRUPT_JSON_LABEL = 'anomaly_type="corrupt_json"'

# Prometheus text format: metric{labels} value [timestamp]
METRIC_LINE_RE = re.compile(
    r"^(?P<name>[a-zA-Z_:][a-zA-Z0-9_:]*"
    r"(?:\{[^}]*\})?)\s+(?P<value>[-+]?[0-9]*\.?[0-9]+(?:[eE][-+]?[0-9]+)?)"
)


@dataclass(frozen=True)
class MetricsSnapshot:
    memory_usage_bytes: float
    corrupt_json_total: float
    fetched_at: datetime
    raw_metrics: dict[str, float]


@dataclass(frozen=True)
class AlertEvaluation:
    breached: bool
    reasons: tuple[str, ...]
    memory_bytes: float
    corrupt_json_total: float
    corrupt_json_delta: float | None


def fetch_metrics(url: str = METRICS_URL, timeout: float = FETCH_TIMEOUT_SECONDS) -> str:
    request = urllib.request.Request(url, method="GET")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8")


def parse_metrics(text: str) -> MetricsSnapshot:
    memory_bytes = 0.0
    corrupt_json_total = 0.0
    parsed: dict[str, float] = {}

    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        match = METRIC_LINE_RE.match(stripped)
        if not match:
            continue

        name = match.group("name")
        value = float(match.group("value"))
        parsed[name] = value

        if name == METRIC_MEMORY:
            memory_bytes = value
        elif name.startswith(METRIC_CORRUPT_JSON) and CORRUPT_JSON_LABEL in name:
            corrupt_json_total = value

    return MetricsSnapshot(
        memory_usage_bytes=memory_bytes,
        corrupt_json_total=corrupt_json_total,
        fetched_at=datetime.now(timezone.utc),
        raw_metrics=parsed,
    )


def evaluate_thresholds(
    current: MetricsSnapshot,
    previous: MetricsSnapshot | None,
    *,
    memory_threshold: int = MEMORY_THRESHOLD_BYTES,
    corrupt_delta_threshold: int = CORRUPT_JSON_DELTA_THRESHOLD,
) -> AlertEvaluation:
    reasons: list[str] = []
    corrupt_delta: float | None = None

    if current.memory_usage_bytes > memory_threshold:
        reasons.append(
            f"memory_usage {current.memory_usage_bytes:.0f} bytes exceeds "
            f"threshold {memory_threshold} bytes ({memory_threshold / 1_048_576:.2f} MiB)"
        )

    if previous is not None:
        corrupt_delta = current.corrupt_json_total - previous.corrupt_json_total
        if corrupt_delta > corrupt_delta_threshold:
            reasons.append(
                f"corrupt_json anomalies increased by {corrupt_delta:.0f} "
                f"(threshold: >{corrupt_delta_threshold} per poll interval)"
            )

    return AlertEvaluation(
        breached=bool(reasons),
        reasons=tuple(reasons),
        memory_bytes=current.memory_usage_bytes,
        corrupt_json_total=current.corrupt_json_total,
        corrupt_json_delta=corrupt_delta,
    )


def format_incident_report(
    evaluation: AlertEvaluation,
    snapshot: MetricsSnapshot,
    metrics_url: str,
) -> str:
    timestamp = snapshot.fetched_at.isoformat()
    reason_block = "\n".join(f"  - {reason}" for reason in evaluation.reasons)
    delta_display = (
        f"{evaluation.corrupt_json_delta:.0f}"
        if evaluation.corrupt_json_delta is not None
        else "n/a (first sample)"
    )

    return (
        "\n"
        "================================================================================\n"
        "=== [CRITICAL ALERT] PIPELINE SLA BREACHED ===\n"
        "================================================================================\n"
        f"  Timestamp (UTC)       : {timestamp}\n"
        f"  Metrics endpoint      : {metrics_url}\n"
        f"  Severity              : CRITICAL\n"
        f"  Service               : vanguard-telemetry-monitor\n"
        "--------------------------------------------------------------------------------\n"
        "  BREACH DETAILS\n"
        f"{reason_block}\n"
        "--------------------------------------------------------------------------------\n"
        "  ACTIVE METRICS\n"
        f"  vanguard_memory_usage_bytes              : {evaluation.memory_bytes:.0f}\n"
        f"  vanguard_anomalies_detected_total        : {evaluation.corrupt_json_total:.0f} "
        f"(corrupt_json)\n"
        f"  corrupt_json delta (since last poll)     : {delta_display}\n"
        "--------------------------------------------------------------------------------\n"
        "  ON-CALL ACTION REQUIRED\n"
        "  1. Inspect telemetry-daemon logs: docker logs telemetry-daemon\n"
        "  2. Review Grafana anomaly panels: http://localhost:3000\n"
        "  3. Execute recovery: ./scripts/health-check.sh or docker compose restart\n"
        "================================================================================\n"
    )


def emit_critical_alert(
    evaluation: AlertEvaluation,
    snapshot: MetricsSnapshot,
    metrics_url: str = METRICS_URL,
) -> None:
    report = format_incident_report(evaluation, snapshot, metrics_url)
    sys.stdout.write(report)
    sys.stdout.flush()


def run_poll_loop(
    *,
    metrics_url: str,
    interval: float,
    once: bool,
    memory_threshold: int,
    corrupt_delta_threshold: int,
) -> int:
    previous: MetricsSnapshot | None = None
    alerts_fired = 0

    while True:
        try:
            raw = fetch_metrics(metrics_url)
            snapshot = parse_metrics(raw)
        except (urllib.error.URLError, TimeoutError, ValueError) as exc:
            print(
                f"[{datetime.now(timezone.utc).isoformat()}] [ERROR] "
                f"Failed to fetch metrics from {metrics_url}: {exc}",
                file=sys.stderr,
            )
            if once:
                return 1
            time.sleep(interval)
            continue

        evaluation = evaluate_thresholds(
            snapshot,
            previous,
            memory_threshold=memory_threshold,
            corrupt_delta_threshold=corrupt_delta_threshold,
        )

        if evaluation.breached:
            emit_critical_alert(evaluation, snapshot, metrics_url)
            alerts_fired += 1

        previous = snapshot

        if once:
            return 1 if alerts_fired else 0

        time.sleep(interval)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Vanguard automated incident controller — Prometheus metrics alert handler.",
    )
    parser.add_argument(
        "--metrics-url",
        default=METRICS_URL,
        help=f"Prometheus metrics endpoint (default: {METRICS_URL})",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=POLL_INTERVAL_SECONDS,
        help=f"Poll interval in seconds (default: {POLL_INTERVAL_SECONDS})",
    )
    parser.add_argument(
        "--once",
        action="store_true",
        help="Run a single evaluation cycle and exit",
    )
    parser.add_argument(
        "--memory-threshold",
        type=int,
        default=MEMORY_THRESHOLD_BYTES,
        help=f"Memory alert threshold in bytes (default: {MEMORY_THRESHOLD_BYTES})",
    )
    parser.add_argument(
        "--corrupt-delta-threshold",
        type=int,
        default=CORRUPT_JSON_DELTA_THRESHOLD,
        help=f"corrupt_json counter delta threshold (default: {CORRUPT_JSON_DELTA_THRESHOLD})",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)

    return run_poll_loop(
        metrics_url=args.metrics_url,
        interval=args.interval,
        once=args.once,
        memory_threshold=args.memory_threshold,
        corrupt_delta_threshold=args.corrupt_delta_threshold,
    )


if __name__ == "__main__":
    sys.exit(main())
