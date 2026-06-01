# Phase 4 Completion — Vanguard Telemetry Monitor

Phase 4 delivers **Test-Driven Validation & Alert Simulation** — a pytest suite for automated quality gates, an on-call-style alert handler that monitors Prometheus metrics, and GitHub Actions CI that blocks broken code from reaching `main`.

This is the **final phase** of the Vanguard Telemetry Monitor platform.

---

## Files Created / Modified

| File | Action | Purpose |
|------|--------|---------|
| `tests/test_daemon.py` | Created | Pytest suite for telemetry schema, anomalies, and health server. |
| `tests/test_alert_handler.py` | Created | Pytest suite for alert threshold logic and incident report formatting. |
| `tests/conftest.py` | Created | Shared fixtures; resets daemon state between tests. |
| `pytest.ini` | Created | Cross-platform pytest config (`pythonpath = src`). |
| `requirements-dev.txt` | Created | Test dependencies (`pytest`, `pytest-cov`). |
| `src/alert_handler.py` | Created | Automated incident controller polling `/metrics`. |
| `.github/workflows/ci.yml` | Created | GitHub Actions: pytest + Docker build on push/PR. |
| `phasecompletion.md` | Created | This document. |

### Full platform inventory (Phases 1–4)

| Layer | Key files |
|-------|-----------|
| Application | `src/daemon.py`, `Dockerfile`, `requirements.txt` |
| Automation | `scripts/deploy-factory.sh`, `scripts/health-check.sh` |
| Observability | `docker-compose.yml`, `prometheus/prometheus.yml`, `grafana/provisioning/` |
| Validation & alerts | `tests/`, `src/alert_handler.py`, `.github/workflows/ci.yml` |

---

## Test Suite Architecture

```
tests/
├── conftest.py              # Autouse fixture: reset _stats, _memory_leak_buffer
├── test_daemon.py           # Daemon unit tests (schema, anomalies, health HTTP)
└── test_alert_handler.py    # Alert handler unit tests (parse, thresholds, report)
```

### Test categories

| Module | Test class | Validates |
|--------|------------|-----------|
| `test_daemon.py` | `TestTelemetrySchema` | Required fields, types, ranges, JSON serializability, counter increment |
| `test_daemon.py` | `TestAnomalyInjection` | Memory leak, corrupt JSON, CPU spike stat increments; Prometheus counter |
| `test_daemon.py` | `TestHealthServer` | `/health`, `/healthz`, `/` return 200 + `status: ok`; unknown paths → 404 |
| `test_alert_handler.py` | `TestAlertHandler` | Metric parsing, threshold breaches, healthy baseline, incident report banner |

### Test coverage metrics

Last run (macOS, Python 3.12+):

| Module | Statements | Coverage | Notes |
|--------|------------|----------|-------|
| `daemon.py` | 144 | **72%** | Main loop, signal handlers, and `main()` excluded (integration scope) |
| `alert_handler.py` | 109 | **69%** | Poll loop and CLI entrypoint excluded (integration scope) |
| **Total** | **253** | **71%** | CI gate: `--cov-fail-under=65` |

Uncovered lines are intentionally integration/runtime paths (`telemetry_loop`, `main`, poll loop) that require long-running processes or live Docker stacks.

### Cross-platform execution

Tests use only stdlib + project dependencies — no OS-specific syscalls. The `pytest.ini` `pythonpath = src` setting ensures imports work identically on:

- macOS (Apple Silicon / Intel)
- Linux (GitHub Actions `ubuntu-latest`)
- Windows (Git Bash / WSL)

---

## Alert Handler — Thresholds & Workflow

`src/alert_handler.py` polls the daemon's Prometheus endpoint and simulates an on-call engineering response.

### Default configuration

| Parameter | Default | Environment variable |
|-----------|---------|----------------------|
| Metrics URL | `http://127.0.0.1:8000/metrics` | `METRICS_URL` |
| Poll interval | `10` seconds | `ALERT_POLL_INTERVAL` |
| Fetch timeout | `5` seconds | `ALERT_FETCH_TIMEOUT` |
| Memory threshold | **15,000,000 bytes (15 MiB)** | `MEMORY_ALERT_THRESHOLD_BYTES` |
| Corrupt JSON delta | **> 3 per poll interval** | `CORRUPT_JSON_DELTA_THRESHOLD` |

### Breach conditions (either triggers CRITICAL alert)

1. **Memory SLA breach** — `vanguard_memory_usage_bytes` > 15,000,000
2. **Corrupt JSON spike** — `vanguard_anomalies_detected_total{anomaly_type="corrupt_json"}` increased by more than 3 since the previous poll

### Alert output format

When a threshold is breached, the handler prints a structured incident report:

```
================================================================================
=== [CRITICAL ALERT] PIPELINE SLA BREACHED ===
================================================================================
  Timestamp (UTC)       : 2026-06-01T15:00:00+00:00
  Metrics endpoint      : http://127.0.0.1:8000/metrics
  Severity              : CRITICAL
  ...
  ON-CALL ACTION REQUIRED
  1. Inspect telemetry-daemon logs: docker logs telemetry-daemon
  2. Review Grafana anomaly panels: http://localhost:3000
  3. Execute recovery: ./scripts/health-check.sh or docker compose restart
================================================================================
```

### CLI usage

```bash
# Continuous monitoring (default 10s interval)
python src/alert_handler.py

# Single evaluation cycle
python src/alert_handler.py --once

# Custom thresholds
python src/alert_handler.py --memory-threshold 10000000 --corrupt-delta-threshold 2

# Against compose stack
python src/alert_handler.py --metrics-url http://127.0.0.1:8000/metrics --once
```

---

## GitHub Actions CI Pipeline

File: `.github/workflows/ci.yml`

### Triggers

- Every `git push` to `main` or `master`
- Every pull request targeting `main` or `master`

### Jobs

```
┌─────────────────────┐
│  Job: test          │
│  ubuntu-latest      │
│  • checkout         │
│  • setup-python 3.12│
│  • pip install deps │
│  • pytest + cov     │──┐
└─────────────────────┘  │
                         │ needs: test
┌─────────────────────┐  │
│  Job: docker-build  │◄─┘
│  ubuntu-latest      │
│  • docker build     │
│  • smoke test run   │
│  • curl /health     │
│  • curl /metrics    │
└─────────────────────┘
```

### CI guarantees

- All pytest tests pass with ≥ 65% combined coverage
- Docker image builds successfully on Linux
- Container starts and responds on `/health` and `/metrics`

---

## Run Unit Tests Locally (MacBook Pro)

### One-time setup

```bash
cd vanguard-telemetry-monitor

# Create isolated virtual environment (recommended on macOS)
python3 -m venv .venv
source .venv/bin/activate

# Install runtime + test dependencies
pip install -r requirements.txt -r requirements-dev.txt
```

### Run tests

```bash
# Full suite with verbose output
pytest tests/ -v

# With coverage report
pytest tests/ --cov=daemon --cov=alert_handler --cov-report=term-missing

# Single test file
pytest tests/test_daemon.py -v

# Single test
pytest tests/test_daemon.py::TestHealthServer::test_health_endpoint_returns_200_and_ok_status -v
```

Expected result: **16 passed** (11 daemon + 5 alert handler).

### Run alert handler against live stack

```bash
# Start observability stack (Phase 3)
docker compose up -d

# Monitor for SLA breaches
python src/alert_handler.py --once
```

To force a memory alert for demo purposes, deploy with elevated leak probability and wait:

```bash
ANOMALY_MEMORY_LEAK_PROB=0.50 docker compose up -d --build telemetry-daemon
python src/alert_handler.py --interval 5
```

---

## MacBook Pro Validation Checklist

### Unit tests

- [ ] `python3 -m venv .venv && source .venv/bin/activate` succeeds
- [ ] `pip install -r requirements.txt -r requirements-dev.txt` succeeds
- [ ] `pytest tests/ -v` → **16 passed**
- [ ] Coverage report shows ≥ 65% total

### Alert handler

- [ ] `docker compose up -d` — stack running
- [ ] `python src/alert_handler.py --once` — exits 0 (healthy) or prints CRITICAL alert
- [ ] Alert report contains `=== [CRITICAL ALERT] PIPELINE SLA BREACHED ===` when thresholds breached

### CI parity

- [ ] `docker build -t vanguard-telemetry-monitor:local .` succeeds
- [ ] Push to GitHub triggers Actions workflow (when remote configured)

---

## Platform Summary — All Phases Complete

| Phase | Deliverable | Status |
|-------|-------------|--------|
| **1** | Containerized telemetry daemon with anomaly simulation | Complete |
| **2** | Bash automation layer (`deploy-factory.sh`, `health-check.sh`) | Complete |
| **3** | Prometheus + Grafana observability stack | Complete |
| **4** | Pytest validation, alert handler, GitHub Actions CI | Complete |

### End-to-end launch (full platform)

```bash
# 1. Run tests
source .venv/bin/activate && pytest tests/ -v

# 2. Launch observability stack
docker compose up -d --build

# 3. Verify dashboards
open http://localhost:3000    # admin / admin

# 4. Start alert monitoring
python src/alert_handler.py

# 5. Optional — Phase 2 health automation
./scripts/health-check.sh --verbose
```

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| `pytest: command not found` | Activate venv: `source .venv/bin/activate` |
| `ModuleNotFoundError: daemon` | Run from project root; confirm `pytest.ini` exists |
| `externally-managed-environment` (macOS) | Use `python3 -m venv .venv` — do not pip install globally |
| Alert handler connection refused | Start stack: `docker compose up -d` |
| CI coverage failure | Run `pytest --cov=daemon --cov=alert_handler --cov-report=term-missing` locally |

---

## What You Built

A complete, production-pattern telemetry monitoring platform:

- **Generates** realistic vehicle telemetry with injectable anomalies
- **Deploys** cross-platform via Docker with Bash automation
- **Observes** metrics through Prometheus and Grafana dashboards
- **Validates** code quality with pytest on every push
- **Alerts** on SLA breaches with structured on-call incident reports

The Vanguard Telemetry Monitor platform is ready for demonstration, extension, or integration into larger SRE workflows.
