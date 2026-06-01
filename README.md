# Vanguard Telemetry Monitor

[![CI](https://github.com/vanguard/vanguard-telemetry-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/vanguard/vanguard-telemetry-monitor/actions/workflows/ci.yml)

A production-pattern **vehicle telemetry simulation and observability platform** built in four incremental phases. Vanguard generates realistic fleet telemetry, injects production-like anomalies, exposes Prometheus metrics, visualizes dashboards in Grafana, automates deployment and recovery with Bash, and validates every change through pytest and GitHub Actions CI.

Develop on **macOS**, **Windows**, or **Linux** — the core workload always runs inside a containerized **Linux** environment via Docker, mirroring how real fleet infrastructure is operated in the field.

---

## Table of Contents

- [What This Project Does](#what-this-project-does)
- [Problem Statement](#problem-statement)
- [Development Phases](#development-phases)
- [Technology Stack](#technology-stack)
- [Architecture](#architecture)
- [Pipelines & Automation](#pipelines--automation)
- [Repository Layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Configuration Reference](#configuration-reference)
- [Operations Guide](#operations-guide)
- [Testing](#testing)
- [Alerting & On-Call Simulation](#alerting--on-call-simulation)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## What This Project Does

Vanguard Telemetry Monitor is an end-to-end **data infrastructure and SRE training platform** that:

1. **Simulates** a continuous stream of vehicle telemetry (JSON logs with `vehicle_id`, `timestamp`, `speed`, `fuel_level`, `sensor_status`).
2. **Injects anomalies** — CPU spikes (~90% utilization), memory leaks, and malformed JSON payloads — to exercise monitoring and incident response workflows.
3. **Exposes metrics** via a Prometheus-compatible `/metrics` endpoint and structured health checks on `/health`.
4. **Scrapes and visualizes** telemetry in Prometheus and Grafana, following patterns used by Datadog and AWS CloudWatch in production environments.
5. **Automates** deployment, health triage, and cold-restart recovery through enterprise-grade Bash scripts.
6. **Validates** code quality with pytest and blocks regressions through GitHub Actions CI on every push and pull request.
7. **Alerts** on SLA breaches through a standalone incident controller that prints structured on-call reports.

---

## Problem Statement

Fleet telemetry platforms must handle high-volume JSON streams, detect anomalies quickly, and give operators actionable visibility — all while remaining deployable across heterogeneous developer machines and Linux production hosts.

This repository solves that challenge by providing a **self-contained reference implementation** that demonstrates:

| Challenge | Vanguard solution |
|-----------|-------------------|
| Cross-platform development vs. Linux production targets | Docker multi-stage builds; host OS runs containers, workload runs Linux |
| Silent failures in automation scripts | `set -euo pipefail`, timestamped logging, explicit error messages |
| No visibility into simulated failures | Prometheus counters/gauges + Grafana dashboards |
| Manual deploy and recovery toil | `deploy-factory.sh` and cron-ready `health-check.sh` |
| Unvalidated changes reaching production | pytest suite + CI coverage gate + Docker smoke tests |
| Untested on-call response | `alert_handler.py` with configurable SLA thresholds |

---

## Development Phases

The platform was built incrementally. Each phase is fully functional on its own and composes into the complete system.

| Phase | Name | Deliverable | Key files |
|-------|------|-------------|-----------|
| **1** | Containerized Telemetry Daemon | Python background service emitting JSON telemetry with anomaly simulation | `src/daemon.py`, `Dockerfile`, `requirements.txt` |
| **2** | Linux Systems Automation Layer | Host-to-container orchestration, health triage, cold restart | `scripts/deploy-factory.sh`, `scripts/health-check.sh` |
| **3** | Observability Architecture | Prometheus scraping + Grafana dashboards via Docker Compose | `docker-compose.yml`, `prometheus/`, `grafana/` |
| **4** | Test-Driven Validation & Alert Simulation | pytest suite, alert handler, GitHub Actions CI | `tests/`, `src/alert_handler.py`, `.github/workflows/ci.yml` |

Detailed phase notes are in [`phasecompletion.md`](phasecompletion.md).

---

## Technology Stack

| Layer | Technology | Version / notes |
|-------|------------|-----------------|
| **Application** | Python | 3.12 |
| **Base image** | Alpine Linux | `python:3.12-alpine` multi-stage |
| **Structured logging** | python-json-logger | JSON stdout logs |
| **Metrics exposition** | prometheus_client | Counter, Gauge on port 8000 |
| **Metrics storage** | Prometheus | v2.52.0, 5s scrape interval |
| **Visualization** | Grafana | v11.0.0, auto-provisioned dashboards |
| **Orchestration** | Docker Compose | v2, bridge network `vanguard-net` |
| **Automation** | Bash | POSIX-oriented, cross-platform via Docker CLI |
| **Testing** | pytest, pytest-cov | 16 tests, ≥65% coverage gate |
| **CI/CD** | GitHub Actions | Ubuntu runner, test + Docker build jobs |
| **Init process** | tini | Proper SIGTERM forwarding in containers |

---

## Architecture

### High-level system diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  Developer Host (macOS / Windows / Linux + Docker Desktop)                   │
│                                                                              │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────────┐   │
│  │ deploy-factory.sh│  │  health-check.sh │  │  alert_handler.py        │   │
│  │ (deploy / stop)  │  │  (triage/recover)│  │  (SLA breach alerts)     │   │
│  └────────┬─────────┘  └────────┬─────────┘  └────────────┬─────────────┘   │
│           │                     │                          │                 │
│           └─────────────────────┼──────────────────────────┘                 │
│                                 │ Docker CLI / HTTP                          │
│                                 ▼                                            │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │  Docker network: vanguard-net                                          │  │
│  │                                                                        │  │
│  │  ┌─────────────────────┐   scrape 5s   ┌─────────────┐   proxy  ┌──────┐│  │
│  │  │  telemetry-daemon   │ ──────────► │ prometheus  │ ────────► │grafana││  │
│  │  │  :8080  /health     │             │   :9090     │           │ :3000 ││  │
│  │  │  :8000  /metrics    │             └─────────────┘           └──────┘│  │
│  │  │  src/daemon.py      │                                              │  │
│  │  └─────────────────────┘                                              │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────┐
│  GitHub Actions CI (on push / PR)                                            │
│  Job 1: pytest + coverage  ──►  Job 2: docker build + smoke test             │
└──────────────────────────────────────────────────────────────────────────────┘
```

### Telemetry and metrics flow

```
daemon loop (every 1s default)
    │
    ├──► JSON log ──► stdout (structured telemetry + anomaly events)
    │
    ├──► Counter  vanguard_telemetry_emitted_total
    ├──► Counter  vanguard_anomalies_detected_total{anomaly_type}
    └──► Gauge    vanguard_memory_usage_bytes
              │
              ▼
         GET /metrics :8000
              │
              ▼
         Prometheus (5s scrape)
              │
              ▼
         Grafana dashboards (5s refresh)
```

### Exposed endpoints

| Endpoint | Port | Purpose |
|----------|------|---------|
| `GET /health` | 8080 | Liveness probe; returns `{"status":"ok","stats":{...}}` |
| `GET /metrics` | 8000 | Prometheus exposition format |
| Prometheus UI | 9090 | PromQL queries, target status |
| Grafana UI | 3000 | Operational dashboards (`admin` / `admin` default) |

### Prometheus metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `vanguard_telemetry_emitted_total` | Counter | — | Successful telemetry packets emitted |
| `vanguard_anomalies_detected_total` | Counter | `anomaly_type` | Anomalies: `cpu_spike`, `memory_leak`, `corrupt_json` |
| `vanguard_memory_usage_bytes` | Gauge | — | Bytes retained in simulated memory-leak buffer |

---

## Pipelines & Automation

### 1. GitHub Actions CI (`.github/workflows/ci.yml`)

**Triggers:** push and pull request to `main` / `master`

| Job | Steps | Gate |
|-----|-------|------|
| **Unit Tests** | Checkout → Python 3.12 → `pip install` → `pytest` | ≥65% coverage, all tests pass |
| **Docker Build** | Build image → run container → curl `/health` + `/metrics` | Image must start and respond |

### 2. Deploy pipeline (`scripts/deploy-factory.sh`)

Master automation for single-container deployments (Phase 1/2 workflow):

```bash
./scripts/deploy-factory.sh --build          # Build and start
./scripts/deploy-factory.sh --status         # Inspect state
./scripts/deploy-factory.sh --stop           # Graceful teardown
```

Performs Docker daemon checks, port availability validation, directory sanity checks, and injects runtime config as `-e` environment variables.

### 3. Health & recovery pipeline (`scripts/health-check.sh`)

Cron-ready triage script:

- Probes `/health` with strict curl timeouts
- Inspects `docker stats` for CPU/memory ceilings
- After 3 consecutive failures or resource breach → logs incident → cold restart via `deploy-factory.sh`

```bash
./scripts/health-check.sh --verbose
./scripts/health-check.sh --dry-run
```

### 4. Observability pipeline (`docker compose`)

Full three-service stack for Phase 3+:

```bash
docker compose up -d --build
docker compose down        # stop
docker compose down -v     # stop + remove volumes
```

### 5. Alert pipeline (`src/alert_handler.py`)

Polls `/metrics` and emits structured CRITICAL alerts when:

- `vanguard_memory_usage_bytes` > **15 MiB**, or
- `corrupt_json` counter increases by **> 3** since last poll

---

## Repository Layout

```
vanguard-telemetry-monitor/
├── src/
│   ├── daemon.py                 # Telemetry generator, anomalies, health + metrics servers
│   └── alert_handler.py          # SLA monitoring and on-call incident reports
├── tests/
│   ├── conftest.py               # Shared pytest fixtures
│   ├── test_daemon.py            # Schema, anomaly, health server tests
│   └── test_alert_handler.py     # Alert threshold and report tests
├── scripts/
│   ├── deploy-factory.sh         # Master deploy/teardown automation
│   └── health-check.sh           # Cron-ready triage and cold restart
├── prometheus/
│   └── prometheus.yml            # Scrape config (telemetry-daemon:8000, 5s)
├── grafana/
│   └── provisioning/
│       ├── datasources/          # Auto-register Prometheus
│       └── dashboards/           # Pre-baked Vanguard dashboard JSON
├── .github/
│   └── workflows/
│       └── ci.yml                # GitHub Actions: pytest + Docker build
├── .runtime/                     # Created at runtime (health state, incidents)
├── logs/                         # Reserved for future log aggregation
├── Dockerfile                    # Multi-stage Alpine build, non-root user
├── docker-compose.yml            # telemetry-daemon + prometheus + grafana
├── requirements.txt              # Runtime Python dependencies
├── requirements-dev.txt          # pytest, pytest-cov
├── pytest.ini                    # Cross-platform test configuration
├── phasecompletion.md            # Phase-by-phase completion documentation
└── README.md                     # This file
```

---

## Prerequisites

| Requirement | Minimum version | Notes |
|-------------|-----------------|-------|
| Docker Desktop / Docker Engine | 20.10+ | Required for all runtime workflows |
| Docker Compose | v2 | `docker compose` (not legacy `docker-compose`) |
| Python | 3.12+ | Local testing and alert handler |
| Git | any recent | Clone and CI |
| curl | any | Health checks and verification |

**Supported host OS:** macOS (Apple Silicon & Intel), Linux, Windows (via Docker Desktop + Git Bash/WSL for scripts).

**Free ports (defaults):** `8080`, `8000`, `9090`, `3000`

---

## Quick Start

### Option A — Full observability stack (recommended)

```bash
git clone https://github.com/vanguard/vanguard-telemetry-monitor.git
cd vanguard-telemetry-monitor

# Launch daemon + Prometheus + Grafana
docker compose up -d --build

# Verify
curl -s http://localhost:8080/health | python3 -m json.tool
curl -s http://localhost:8000/metrics | grep vanguard_
```

| Service | URL | Credentials |
|---------|-----|-------------|
| Grafana dashboard | http://localhost:3000 | `admin` / `admin` |
| Prometheus | http://localhost:9090/targets | — |
| Health | http://localhost:8080/health | — |
| Metrics | http://localhost:8000/metrics | — |

Open **Dashboards → Vanguard → Vanguard Telemetry Monitor** in Grafana.

### Option B — Single container (Phase 1/2)

```bash
chmod +x scripts/*.sh
./scripts/deploy-factory.sh --build
curl http://localhost:8080/health
```

### Option C — Local development with tests

```bash
python3 -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt -r requirements-dev.txt
pytest tests/ -v
```

---

## Configuration Reference

### Daemon environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TELEMETRY_INTERVAL` | `1.0` | Seconds between telemetry emissions |
| `VEHICLE_IDS` | `VH-001,...,VH-005` | Comma-separated fleet identifiers |
| `ANOMALY_CPU_SPIKE_PROB` | `0.02` | CPU spike probability per tick |
| `ANOMALY_MEMORY_LEAK_PROB` | `0.01` | Memory leak probability per tick |
| `ANOMALY_CORRUPT_JSON_PROB` | `0.015` | Corrupt JSON probability per tick |
| `HEALTH_PORT` | `8080` | Health HTTP server port |
| `METRICS_PORT` | `8000` | Prometheus metrics port |
| `CPU_SPIKE_DURATION` | `3.0` | CPU spike duration (seconds) |
| `CPU_SPIKE_THREADS` | `4` | Worker threads during CPU spike |
| `MEMORY_LEAK_CHUNK_KB` | `512` | KB retained per memory leak event |

### Docker Compose host port overrides

```bash
HOST_GRAFANA_PORT=3001 HOST_PROMETHEUS_PORT=9091 docker compose up -d
```

| Variable | Default |
|----------|---------|
| `HOST_HEALTH_PORT` | `8080` |
| `HOST_METRICS_PORT` | `8000` |
| `HOST_PROMETHEUS_PORT` | `9090` |
| `HOST_GRAFANA_PORT` | `3000` |
| `GRAFANA_ADMIN_USER` | `admin` |
| `GRAFANA_ADMIN_PASSWORD` | `admin` |

### Alert handler thresholds

| Variable | Default |
|----------|---------|
| `METRICS_URL` | `http://127.0.0.1:8000/metrics` |
| `MEMORY_ALERT_THRESHOLD_BYTES` | `15000000` (15 MiB) |
| `CORRUPT_JSON_DELTA_THRESHOLD` | `3` |
| `ALERT_POLL_INTERVAL` | `10` seconds |

---

## Operations Guide

### View logs

```bash
docker compose logs -f telemetry-daemon
docker logs -f telemetry-daemon
```

### Restart a single service

```bash
docker compose restart telemetry-daemon
```

### Run health automation

```bash
./scripts/health-check.sh --verbose
```

### Schedule health checks (cron)

```bash
*/2 * * * * /path/to/vanguard-telemetry-monitor/scripts/health-check.sh \
  >> /path/to/vanguard-telemetry-monitor/.runtime/health-check.log 2>&1
```

### Start alert monitoring

```bash
source .venv/bin/activate
python src/alert_handler.py                  # continuous
python src/alert_handler.py --once           # single check
```

### Tear down everything

```bash
docker compose down -v
./scripts/deploy-factory.sh --stop
```

---

## Testing

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt -r requirements-dev.txt

# Full suite
pytest tests/ -v

# With coverage (matches CI)
pytest tests/ --cov=daemon --cov=alert_handler --cov-report=term-missing --cov-fail-under=65
```

| Suite | Tests | Coverage focus |
|-------|-------|----------------|
| `test_daemon.py` | 11 | Telemetry schema, anomaly counters, health HTTP |
| `test_alert_handler.py` | 5 | Metric parsing, SLA thresholds, incident reports |

**Expected result:** 16 passed, ≥65% combined coverage.

---

## Alerting & On-Call Simulation

When SLA thresholds are breached, `alert_handler.py` prints:

```
================================================================================
=== [CRITICAL ALERT] PIPELINE SLA BREACHED ===
================================================================================
  Timestamp (UTC)       : ...
  Severity              : CRITICAL
  ...
  ON-CALL ACTION REQUIRED
  1. Inspect telemetry-daemon logs: docker logs telemetry-daemon
  2. Review Grafana anomaly panels: http://localhost:3000
  3. Execute recovery: ./scripts/health-check.sh or docker compose restart
================================================================================
```

To demo alerts with elevated anomaly rates:

```bash
ANOMALY_MEMORY_LEAK_PROB=0.50 docker compose up -d --build telemetry-daemon
python src/alert_handler.py --interval 5
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Port already in use | Phase 2 container or other service | `./scripts/deploy-factory.sh --stop` or override `HOST_*_PORT` |
| Prometheus target DOWN | Daemon not healthy yet | `docker compose logs telemetry-daemon`; wait for health check |
| Empty Grafana panels | Insufficient scrape time | Set time range to Last 15 minutes; confirm target UP |
| `pytest: command not found` | Virtualenv not activated | `source .venv/bin/activate` |
| `externally-managed-environment` (macOS) | System Python | Use `python3 -m venv .venv` |
| Alert handler connection refused | Stack not running | `docker compose up -d` |
| CI coverage failure | New untested code | Run pytest with `--cov-report=term-missing` locally |

---

## Contributing

1. Fork the repository and create a feature branch.
2. Install dev dependencies: `pip install -r requirements.txt -r requirements-dev.txt`
3. Run tests: `pytest tests/ -v --cov=daemon --cov=alert_handler --cov-fail-under=65`
4. Ensure Docker builds: `docker build -t vanguard-telemetry-monitor:local .`
5. Open a pull request against `main` — CI must pass before merge.

---

## License

This project is provided as a reference implementation for educational and demonstration purposes. Add your organization's license here before production use.

---

## Further Reading

- [`phasecompletion.md`](phasecompletion.md) — Detailed phase documentation, validation checklists, and architecture notes from each development phase.
