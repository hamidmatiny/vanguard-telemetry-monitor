# Phase 3 Completion — Vanguard Telemetry Monitor

Phase 3 delivers an **Observability Architecture & Metrics Engine** — a production-style Prometheus + Grafana stack that collects, stores, and visualizes telemetry daemon metrics, mirroring Datadog/CloudWatch-style monitoring patterns.

---

## Files Created / Modified

| File | Action | Purpose |
|------|--------|---------|
| `src/daemon.py` | Modified | Exposes Prometheus metrics on port 8000 via `prometheus_client`. |
| `requirements.txt` | Modified | Added `prometheus_client==0.21.1`. |
| `Dockerfile` | Modified | Exposes port 8000; sets `METRICS_PORT` default. |
| `docker-compose.yml` | Created | Multi-container stack: daemon, Prometheus, Grafana. |
| `prometheus/prometheus.yml` | Created | Scrape config targeting `telemetry-daemon:8000` every 5s. |
| `grafana/provisioning/datasources/prometheus.yml` | Created | Auto-registers Prometheus as default Grafana datasource. |
| `grafana/provisioning/dashboards/dashboards.yml` | Created | File-based dashboard provider configuration. |
| `grafana/provisioning/dashboards/vanguard-dashboard.json` | Created | Pre-baked operational dashboard. |
| `phasecompletion.md` | Created | This document. |

### Prior phases (unchanged automation layer)

| File | Purpose |
|------|---------|
| `scripts/deploy-factory.sh` | Standalone single-container deploy (Phase 2). |
| `scripts/health-check.sh` | Cron-ready triage and cold restart (Phase 2). |

> **Note:** Phase 3 introduces `docker compose` as the primary way to run the full observability stack. Phase 2 scripts remain valid for single-container workflows.

---

## Metrics Exposition Design

The daemon starts a **Prometheus metrics HTTP server** on port `8000` (configurable via `METRICS_PORT`) using `prometheus_client.start_http_server()`. Metrics are updated synchronously inside the telemetry loop and anomaly handlers.

### Exposed metrics

| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `vanguard_telemetry_emitted_total` | Counter | — | Incremented on every successful JSON telemetry packet. |
| `vanguard_anomalies_detected_total` | Counter | `anomaly_type` | Incremented when an anomaly fires. Values: `cpu_spike`, `memory_leak`, `corrupt_json`. |
| `vanguard_memory_usage_bytes` | Gauge | — | Bytes retained in the simulated memory-leak buffer; updated each loop iteration. |

### Endpoint

```
GET http://telemetry-daemon:8000/metrics
```

Example excerpt:

```
# HELP vanguard_telemetry_emitted_total Total successful JSON telemetry packets emitted
# TYPE vanguard_telemetry_emitted_total counter
vanguard_telemetry_emitted_total 142.0
# HELP vanguard_anomalies_detected_total Total production anomalies detected by type
# TYPE vanguard_anomalies_detected_total counter
vanguard_anomalies_detected_total{anomaly_type="cpu_spike"} 3.0
vanguard_anomalies_detected_total{anomaly_type="memory_leak"} 1.0
vanguard_anomalies_detected_total{anomaly_type="corrupt_json"} 2.0
# HELP vanguard_memory_usage_bytes Simulated memory consumption retained by the daemon process
# TYPE vanguard_memory_usage_bytes gauge
vanguard_memory_usage_bytes 524288.0
```

### Design rationale (Datadog / CloudWatch parity)

| Production pattern | Vanguard implementation |
|--------------------|-------------------------|
| Custom application counters | `vanguard_telemetry_emitted_total`, `vanguard_anomalies_detected_total` |
| Dimensional tagging | `anomaly_type` label on anomaly counter |
| Resource utilization gauges | `vanguard_memory_usage_bytes` |
| Pull-based metric collection | Prometheus scrapes `/metrics` every 5s |
| Dashboards & visualization | Grafana auto-provisioned dashboard |

---

## Multi-Container Compose Networking Topology

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  Host (macOS / Linux / Windows + Docker Desktop)                            │
│                                                                             │
│  Published ports:                                                           │
│    localhost:8080  → telemetry-daemon:8080  (health)                        │
│    localhost:8000  → telemetry-daemon:8000  (Prometheus metrics)            │
│    localhost:9090  → prometheus:9090        (Prometheus UI)                 │
│    localhost:3000  → grafana:3000             (Grafana UI)                    │
│                                                                             │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  Docker network: vanguard-net (bridge)                                │  │
│  │                                                                       │  │
│  │  ┌─────────────────┐    scrape :8000/5s    ┌─────────────────┐       │  │
│  │  │ telemetry-daemon│ ─────────────────────► │   prometheus    │       │  │
│  │  │  :8080 health   │                        │     :9090       │       │  │
│  │  │  :8000 metrics  │                        └────────┬────────┘       │  │
│  │  └─────────────────┘                                 │ proxy           │  │
│  │                                                      ▼                 │  │
│  │                                             ┌─────────────────┐       │  │
│  │                                             │    grafana      │       │  │
│  │                                             │     :3000       │       │  │
│  │                                             └─────────────────┘       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Service dependency chain

1. **telemetry-daemon** starts first; must pass health check on `:8080`.
2. **prometheus** starts after daemon is healthy; scrapes internal DNS name `telemetry-daemon:8000`.
3. **grafana** starts after Prometheus; datasource URL `http://prometheus:9090` resolves on `vanguard-net`.

### Cross-platform compatibility

- Uses standard Compose v2 syntax (`docker compose`) — works on Docker Desktop for macOS (Apple Silicon native ARM), Linux, and Windows.
- No host-specific bind mounts beyond relative project paths.
- Named volumes (`vanguard-prometheus-data`, `vanguard-grafana-data`) persist metrics and dashboard state across restarts.
- Override ports via environment variables without editing compose file:

```bash
HOST_GRAFANA_PORT=3001 HOST_PROMETHEUS_PORT=9091 docker compose up -d
```

---

## Grafana Dashboard Panels

The auto-provisioned **Vanguard Telemetry Monitor** dashboard (`uid: vanguard-telemetry`) includes:

| Panel | Query | Purpose |
|-------|-------|---------|
| Vehicle Telemetry Frequency | `rate(vanguard_telemetry_emitted_total[1m])` | Real-time timeline of incoming packet rate |
| Anomaly Breakdown | `sum by (anomaly_type) (vanguard_anomalies_detected_total)` | Donut chart of caught anomalies by type |
| Simulated Memory Allocation | `vanguard_memory_usage_bytes` | Gauge with threshold coloring |
| Anomaly Detection Rate | `increase(...[5m])` by type | Stacked bar timeline of anomaly events |
| Total Telemetry Packets | `vanguard_telemetry_emitted_total` | Stat panel |
| Total Anomalies Detected | `sum(vanguard_anomalies_detected_total)` | Stat panel |
| Memory Utilization Timeline | `vanguard_memory_usage_bytes` | Line graph over time |

Dashboard refresh: **5 seconds** (aligned with Prometheus scrape interval).

---

## Launch & Verification Guide

### Prerequisites

- Docker Desktop running (macOS/Windows) or Docker Engine (Linux)
- Docker Compose v2 (`docker compose version`)
- Ports **8080**, **8000**, **9090**, **3000** available on the host

### 1. Stop conflicting Phase 2 containers (if running)

```bash
./scripts/deploy-factory.sh --stop
```

### 2. Launch the full observability stack

From the project root:

```bash
docker compose up -d --build
```

Expected services:

```
telemetry-daemon   healthy
prometheus         running
grafana            running
```

Monitor startup:

```bash
docker compose ps
docker compose logs -f telemetry-daemon
```

### 3. Verify metrics exposition

```bash
# Raw Prometheus metrics from daemon
curl -s http://localhost:8000/metrics | grep vanguard_

# Health endpoint (Phase 1/2)
curl -s http://localhost:8080/health
```

- [ ] `vanguard_telemetry_emitted_total` counter is incrementing
- [ ] `vanguard_anomalies_detected_total` appears with `anomaly_type` labels after anomalies fire
- [ ] `vanguard_memory_usage_bytes` increases when memory-leak anomalies occur

### 4. Verify Prometheus scraping

Open **http://localhost:9090** → **Status → Targets**.

- [ ] Target `vanguard-telemetry` shows **UP**
- [ ] Last scrape ~5s ago
- [ ] Endpoint `http://telemetry-daemon:8000/metrics`

Query in Prometheus UI:

```promql
rate(vanguard_telemetry_emitted_total[1m])
```

### 5. Verify Grafana dashboard

Open **http://localhost:3000**

| Field | Value |
|-------|-------|
| Username | `admin` |
| Password | `admin` |

Navigate: **Dashboards → Vanguard → Vanguard Telemetry Monitor**

- [ ] Telemetry frequency graph shows ~1 packet/sec (default interval)
- [ ] Anomaly donut chart populates over time
- [ ] Memory gauge reflects simulated leak buffer growth
- [ ] Dashboard auto-refreshes every 5 seconds

### 6. Optional — increase anomaly rate for faster demo

```bash
ANOMALY_CPU_SPIKE_PROB=0.10 ANOMALY_MEMORY_LEAK_PROB=0.08 ANOMALY_CORRUPT_JSON_PROB=0.08 \
  docker compose up -d --build telemetry-daemon
```

Watch panels update within 5–10 seconds.

### 7. Tear down

```bash
# Stop containers (retain volumes)
docker compose down

# Stop and remove volumes (full reset)
docker compose down -v
```

---

## Environment Variables Reference

| Variable | Default | Service | Description |
|----------|---------|---------|-------------|
| `HOST_HEALTH_PORT` | `8080` | compose | Host port for daemon health |
| `HOST_METRICS_PORT` | `8000` | compose | Host port for Prometheus metrics |
| `HOST_PROMETHEUS_PORT` | `9090` | compose | Host port for Prometheus UI |
| `HOST_GRAFANA_PORT` | `3000` | compose | Host port for Grafana UI |
| `GRAFANA_ADMIN_USER` | `admin` | grafana | Grafana login user |
| `GRAFANA_ADMIN_PASSWORD` | `admin` | grafana | Grafana login password |
| `TELEMETRY_INTERVAL` | `1.0` | telemetry-daemon | Seconds between emissions |
| `ANOMALY_CPU_SPIKE_PROB` | `0.02` | telemetry-daemon | CPU spike probability |
| `ANOMALY_MEMORY_LEAK_PROB` | `0.01` | telemetry-daemon | Memory leak probability |
| `ANOMALY_CORRUPT_JSON_PROB` | `0.015` | telemetry-daemon | Corrupt JSON probability |
| `METRICS_PORT` | `8000` | telemetry-daemon | In-container metrics port |

---

## MacBook Pro Validation Checklist

- [ ] `docker compose up -d --build` completes without errors on Apple Silicon
- [ ] `curl localhost:8000/metrics | grep vanguard_telemetry_emitted_total` returns data
- [ ] Prometheus target `telemetry-daemon:8000` is **UP** at http://localhost:9090/targets
- [ ] Grafana loads at http://localhost:3000 with credentials `admin` / `admin`
- [ ] **Vanguard Telemetry Monitor** dashboard shows live graphs within 15 seconds
- [ ] Memory gauge increases after memory-leak anomalies (may take 1–2 minutes at default rates)
- [ ] `docker compose down` cleanly stops all three services

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Port already allocated | Phase 2 container or other service on 8080/3000 | `./scripts/deploy-factory.sh --stop` or change `HOST_*_PORT` vars |
| Prometheus target DOWN | Daemon not healthy yet | `docker compose logs telemetry-daemon`; wait for health check |
| Empty Grafana panels | Prometheus not scraping yet | Confirm target UP; set time range to **Last 15 minutes** |
| Dashboard not appearing | Provisioning path issue | `docker compose logs grafana \| grep provisioning` |
| Metrics stale after rebuild | Old Prometheus volume | `docker compose down -v` and relaunch |

---

## Next Steps (Phase 4+)

Future phases may add Alertmanager rules, Loki log aggregation, OpenTelemetry tracing, and integration with the Phase 2 `health-check.sh` automation layer for unified incident response.
