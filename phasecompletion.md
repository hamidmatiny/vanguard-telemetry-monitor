# Phase 1 Completion — Vanguard Telemetry Monitor

Phase 1 delivers a containerized Linux telemetry simulation daemon that runs identically on macOS (Apple Silicon and Intel), Windows, and Linux hosts via Docker.

---

## Files Created

| File | Purpose |
|------|---------|
| `src/daemon.py` | Background Python service that emits structured vehicle telemetry JSON logs and randomly injects production-like anomalies (CPU spikes, memory leaks, corrupt JSON). |
| `Dockerfile` | Multi-stage Alpine-based image with a non-root runtime user, health checks, and cross-platform compatibility. |
| `requirements.txt` | Pinned Python dependency (`python-json-logger`) for structured JSON logging to stdout. |
| `.dockerignore` | Excludes VCS metadata, virtualenvs, and documentation from the build context for faster, smaller builds. |
| `phasecompletion.md` | This document — build/run instructions and architecture notes for Phase 1. |

---

## Daemon Behavior

### Normal telemetry payload

Each interval (default: 1 second), the daemon emits a log line containing:

```json
{
  "vehicle_id": "VH-003",
  "timestamp": "2026-06-01T12:00:00.123456+00:00",
  "speed": 87.4,
  "fuel_level": 62.1,
  "sensor_status": "ok"
}
```

### Simulated anomalies

| Anomaly | Default probability | Behavior |
|---------|--------------------|----------|
| **CPU spike** | 2% | Spawns 4 worker threads doing CPU-bound work for ~3 seconds, simulating ~90% CPU utilization. |
| **Memory leak** | 1% | Retains 512 KB chunks in an in-process buffer that is never released. |
| **Corrupt JSON** | 1.5% | Writes malformed JSON directly to stdout (truncated braces, invalid syntax, wrong types). |

All probabilities and timings are configurable via environment variables (see below).

### Health endpoint

A lightweight HTTP server listens on port **8080** (`/health`, `/healthz`, `/`) and returns daemon statistics. This supports Docker `HEALTHCHECK` and future Kubernetes liveness probes.

---

## Multi-Stage Dockerfile — Cross-Platform Optimization

```
┌─────────────────────────────────────────────────────────────┐
│  Stage 1: builder (python:3.12-alpine)                      │
│  • Installs gcc/build-base (compile toolchain)              │
│  • Creates isolated venv at /opt/venv                       │
│  • pip install -r requirements.txt                          │
└──────────────────────────┬──────────────────────────────────┘
                           │ COPY /opt/venv only
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Stage 2: runtime (python:3.12-alpine)                      │
│  • No compiler toolchain — smaller attack surface           │
│  • Non-root user `vanguard` (UID 10001)                     │
│  • tini as PID 1 for proper signal forwarding               │
│  • HEALTHCHECK against /health                              │
└─────────────────────────────────────────────────────────────┘
```

### Why this works across macOS, Windows, and Linux

1. **Alpine Linux base** — The container always runs Linux userspace regardless of host OS. Docker Desktop on macOS/Windows transparently handles architecture translation (ARM64 ↔ amd64) when using `--platform` or buildx.
2. **Multi-stage separation** — Build tools (~100 MB+) never ship in the final image, reducing size and startup time.
3. **Virtualenv copy** — Dependencies are fully resolved at build time; the runtime stage has no network access requirement.
4. **Non-root execution** — Follows container security best practices; compatible with restricted Kubernetes/OpenShift policies.
5. **`tini` init** — Ensures SIGTERM from `docker stop` reaches the Python process for graceful shutdown.

---

## Build and Run Instructions

### Prerequisites

- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (macOS / Windows) or Docker Engine (Linux)
- Docker CLI v20.10+ recommended

### Build the image

From the project root:

```bash
docker build -t vanguard-telemetry-monitor:phase1 .
```

#### Apple Silicon (M1/M2/M3) — explicit platform (optional)

```bash
docker build --platform linux/amd64 -t vanguard-telemetry-monitor:phase1 .
# or native ARM:
docker build --platform linux/arm64 -t vanguard-telemetry-monitor:phase1 .
```

### Run the container

```bash
docker run --rm \
  --name vanguard-telemetry \
  -p 8080:8080 \
  vanguard-telemetry-monitor:phase1
```

You should see continuous JSON telemetry logs on stdout and can verify health:

```bash
curl http://localhost:8080/health
```

### Run with custom configuration

```bash
docker run --rm \
  --name vanguard-telemetry \
  -p 8080:8080 \
  -e TELEMETRY_INTERVAL=0.5 \
  -e ANOMALY_CPU_SPIKE_PROB=0.05 \
  -e ANOMALY_MEMORY_LEAK_PROB=0.03 \
  -e ANOMALY_CORRUPT_JSON_PROB=0.04 \
  -e VEHICLE_IDS="FLEET-A,FLEET-B,FLEET-C" \
  vanguard-telemetry-monitor:phase1
```

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TELEMETRY_INTERVAL` | `1.0` | Seconds between telemetry emissions |
| `VEHICLE_IDS` | `VH-001,...,VH-005` | Comma-separated fleet identifiers |
| `ANOMALY_CPU_SPIKE_PROB` | `0.02` | Probability of CPU spike per tick |
| `ANOMALY_MEMORY_LEAK_PROB` | `0.01` | Probability of memory leak per tick |
| `ANOMALY_CORRUPT_JSON_PROB` | `0.015` | Probability of corrupt JSON per tick |
| `CPU_SPIKE_DURATION` | `3.0` | Duration of CPU spike in seconds |
| `CPU_SPIKE_THREADS` | `4` | Worker threads during CPU spike |
| `MEMORY_LEAK_CHUNK_KB` | `512` | KB retained per memory leak event |
| `HEALTH_PORT` | `8080` | HTTP health/metrics port |

### Stop gracefully

```bash
docker stop vanguard-telemetry
```

The daemon handles `SIGTERM` and logs final statistics before exiting.

---

## Verification Checklist

- [ ] `docker build` completes without errors
- [ ] Container starts and streams JSON telemetry to stdout
- [ ] `curl http://localhost:8080/health` returns `{"status":"ok","stats":{...}}`
- [ ] Occasional anomaly log lines appear (`anomaly_detected`)
- [ ] `docker stop` triggers graceful shutdown (`daemon_stopped` log)

---

## Next Steps (Phase 2+)

Phase 1 intentionally produces raw telemetry and anomalies. Subsequent phases will add log aggregation, metrics scraping, alerting rules, and dashboard visualization on top of this foundation.
