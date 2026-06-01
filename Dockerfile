# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Stage 1 — build: compile/install Python dependencies into a virtual env
# ---------------------------------------------------------------------------
FROM python:3.12-alpine AS builder

RUN apk add --no-cache \
    build-base \
    libffi-dev

WORKDIR /build

COPY requirements.txt .

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt


# ---------------------------------------------------------------------------
# Stage 2 — runtime: minimal image with non-root user
# ---------------------------------------------------------------------------
FROM python:3.12-alpine AS runtime

LABEL org.opencontainers.image.title="vanguard-telemetry-monitor" \
      org.opencontainers.image.description="Phase 1 vehicle telemetry simulation daemon" \
      org.opencontainers.image.source="https://github.com/vanguard/vanguard-telemetry-monitor"

RUN apk add --no-cache \
    tini \
    && addgroup -g 10001 vanguard \
    && adduser -D -G vanguard -u 10001 vanguard

WORKDIR /app

COPY --from=builder /opt/venv /opt/venv
COPY --chown=vanguard:vanguard src/ ./src/

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    TELEMETRY_INTERVAL=1.0 \
    HEALTH_PORT=8080

EXPOSE 8080

USER vanguard

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/health')" || exit 1

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["python", "-u", "src/daemon.py"]
