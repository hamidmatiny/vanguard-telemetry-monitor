#!/usr/bin/env bash
# deploy-factory.sh — Master automation for the Vanguard telemetry container stack.
# POSIX-oriented Bash; bridges macOS/Windows/Linux hosts to the Linux container runtime.

set -e
set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly SCRIPT_NAME="deploy-factory"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

readonly CONTAINER_NAME="vanguard-telemetry"
readonly IMAGE_NAME="vanguard-telemetry-monitor"
readonly IMAGE_TAG="phase1"
readonly FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"

readonly RUNTIME_DIR="${PROJECT_ROOT}/.runtime"
readonly LOGS_DIR="${PROJECT_ROOT}/logs"

# Defaults (override via CLI flags or environment)
HOST_PORT="${HOST_PORT:-8080}"
CONTAINER_HEALTH_PORT="${CONTAINER_HEALTH_PORT:-8080}"
TELEMETRY_INTERVAL="${TELEMETRY_INTERVAL:-1.0}"
VEHICLE_IDS="${VEHICLE_IDS:-VH-001,VH-002,VH-003,VH-004,VH-005}"
ANOMALY_CPU_SPIKE_PROB="${ANOMALY_CPU_SPIKE_PROB:-0.02}"
ANOMALY_MEMORY_LEAK_PROB="${ANOMALY_MEMORY_LEAK_PROB:-0.01}"
ANOMALY_CORRUPT_JSON_PROB="${ANOMALY_CORRUPT_JSON_PROB:-0.015}"
DOCKER_PLATFORM="${DOCKER_PLATFORM:-}"

ACTION="deploy"
FORCE_BUILD=0

TEMP_FILES=()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_log() {
    # Usage: _log LEVEL message...
    local level="$1"
    shift
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*"
}

log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@" >&2; }

die() {
    log_error "$@"
    exit 1
}

# ---------------------------------------------------------------------------
# Cleanup / traps
# ---------------------------------------------------------------------------

register_temp_file() {
    TEMP_FILES+=("$1")
}

cleanup() {
    local rc=$?
    local tmp

    for tmp in "${TEMP_FILES[@]:-}"; do
        if [ -n "$tmp" ] && [ -e "$tmp" ]; then
            rm -f "$tmp"
        fi
    done

    if [ "$rc" -ne 0 ]; then
        log_error "${SCRIPT_NAME} exited with status ${rc}"
    fi

    exit "$rc"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME}.sh [OPTIONS]

Master deployment automation for the Vanguard telemetry monitor container.

Options:
  --build                     Force rebuild of the Docker image before deploy
  --stop                      Gracefully stop and remove the running container
  --status                    Print container/image status and exit
  --help                      Show this help message and exit

Runtime configuration:
  --port PORT                 Host port to bind (default: 8080)
  --health-port PORT          In-container health port (default: 8080)
  --interval SECONDS          Telemetry emission interval (default: 1.0)
  --vehicle-ids IDS           Comma-separated vehicle IDs
  --cpu-spike-prob PROB       CPU spike anomaly probability (default: 0.02)
  --memory-leak-prob PROB     Memory leak anomaly probability (default: 0.01)
  --corrupt-json-prob PROB    Corrupt JSON anomaly probability (default: 0.015)
  --platform PLATFORM         Docker platform, e.g. linux/arm64 or linux/amd64

Environment variables:
  HOST_PORT, TELEMETRY_INTERVAL, VEHICLE_IDS,
  ANOMALY_CPU_SPIKE_PROB, ANOMALY_MEMORY_LEAK_PROB, ANOMALY_CORRUPT_JSON_PROB,
  DOCKER_PLATFORM

Examples:
  ${SCRIPT_NAME}.sh
  ${SCRIPT_NAME}.sh --build --port 9090
  ${SCRIPT_NAME}.sh --stop
  ${SCRIPT_NAME}.sh --build --cpu-spike-prob 0.05 --memory-leak-prob 0.03

EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    if [ "$#" -eq 0 ]; then
        return 0
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --build)
                FORCE_BUILD=1
                ;;
            --stop)
                ACTION="stop"
                ;;
            --status)
                ACTION="status"
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --port)
                [ "$#" -ge 2 ] || die "Missing value for --port"
                HOST_PORT="$2"
                shift
                ;;
            --health-port)
                [ "$#" -ge 2 ] || die "Missing value for --health-port"
                CONTAINER_HEALTH_PORT="$2"
                shift
                ;;
            --interval)
                [ "$#" -ge 2 ] || die "Missing value for --interval"
                TELEMETRY_INTERVAL="$2"
                shift
                ;;
            --vehicle-ids)
                [ "$#" -ge 2 ] || die "Missing value for --vehicle-ids"
                VEHICLE_IDS="$2"
                shift
                ;;
            --cpu-spike-prob)
                [ "$#" -ge 2 ] || die "Missing value for --cpu-spike-prob"
                ANOMALY_CPU_SPIKE_PROB="$2"
                shift
                ;;
            --memory-leak-prob)
                [ "$#" -ge 2 ] || die "Missing value for --memory-leak-prob"
                ANOMALY_MEMORY_LEAK_PROB="$2"
                shift
                ;;
            --corrupt-json-prob)
                [ "$#" -ge 2 ] || die "Missing value for --corrupt-json-prob"
                ANOMALY_CORRUPT_JSON_PROB="$2"
                shift
                ;;
            --platform)
                [ "$#" -ge 2 ] || die "Missing value for --platform"
                DOCKER_PLATFORM="$2"
                shift
                ;;
            *)
                die "Unknown option: $1 (use --help for usage)"
                ;;
        esac
        shift
    done
}

# ---------------------------------------------------------------------------
# Host sanity checks
# ---------------------------------------------------------------------------

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
}

check_docker_daemon() {
    require_command docker

    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon is not running or not accessible. Start Docker Desktop and retry."
    fi

    log_info "Docker daemon is active"
}

ensure_directories() {
    local dir

    for dir in "${PROJECT_ROOT}/src" "${SCRIPT_DIR}" "${RUNTIME_DIR}" "${LOGS_DIR}"; do
        if [ ! -d "$dir" ]; then
            log_info "Creating required directory: ${dir}"
            mkdir -p "$dir"
        fi
    done

    if [ ! -f "${PROJECT_ROOT}/Dockerfile" ]; then
        die "Missing Dockerfile at ${PROJECT_ROOT}/Dockerfile"
    fi

    if [ ! -f "${PROJECT_ROOT}/src/daemon.py" ]; then
        die "Missing daemon source at ${PROJECT_ROOT}/src/daemon.py"
    fi

    log_info "Required project directories verified"
}

container_is_running() {
    docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' 2>/dev/null \
        | grep -qx "${CONTAINER_NAME}"
}

container_exists() {
    docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' 2>/dev/null \
        | grep -qx "${CONTAINER_NAME}"
}

port_holder_pid() {
    local port="$1"
    local pid=""

    if command -v lsof >/dev/null 2>&1; then
        pid="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null | head -n 1 || true)"
    elif command -v netstat >/dev/null 2>&1; then
        pid="$(netstat -anv 2>/dev/null | awk -v p="${port}" '
            $4 ~ ":" p "$" && $6 == "LISTEN" { print $9; exit }
        ' || true)"
    fi

    printf '%s' "$pid"
}

check_host_port_available() {
    local port="$1"
    local pid

    pid="$(port_holder_pid "$port")"

    if [ -z "$pid" ]; then
        log_info "Host port ${port} is available"
        return 0
    fi

    if container_is_running; then
        log_info "Host port ${port} is in use by ${CONTAINER_NAME} (expected)"
        return 0
    fi

    die "Host port ${port} is already in use by PID ${pid}. Free the port or pass --port <PORT>."
}

# ---------------------------------------------------------------------------
# Docker operations
# ---------------------------------------------------------------------------

build_image() {
    log_info "Building image ${FULL_IMAGE} from ${PROJECT_ROOT}"

    if [ -n "${DOCKER_PLATFORM}" ]; then
        docker build --platform "${DOCKER_PLATFORM}" -t "${FULL_IMAGE}" "${PROJECT_ROOT}"
    else
        docker build -t "${FULL_IMAGE}" "${PROJECT_ROOT}"
    fi

    log_info "Image build completed: ${FULL_IMAGE}"
}

image_exists() {
    docker image inspect "${FULL_IMAGE}" >/dev/null 2>&1
}

stop_stack() {
    if container_is_running; then
        log_info "Stopping container ${CONTAINER_NAME}"
        docker stop "${CONTAINER_NAME}" >/dev/null
        log_info "Container ${CONTAINER_NAME} stopped"
    elif container_exists; then
        log_info "Removing stopped container ${CONTAINER_NAME}"
        docker rm -f "${CONTAINER_NAME}" >/dev/null 2>&1 || true
    else
        log_info "No running container named ${CONTAINER_NAME}"
    fi
}

deploy_stack() {
    if container_is_running; then
        log_warn "Container ${CONTAINER_NAME} is already running; skipping deploy"
        return 0
    fi

    if container_exists; then
        log_info "Removing stale container ${CONTAINER_NAME}"
        docker rm -f "${CONTAINER_NAME}" >/dev/null
    fi

    if [ "${FORCE_BUILD}" -eq 1 ] || ! image_exists; then
        build_image
    elif ! image_exists; then
        die "Image ${FULL_IMAGE} not found. Re-run with --build."
    fi

    check_host_port_available "${HOST_PORT}"

    log_info "Starting container ${CONTAINER_NAME} (host:${HOST_PORT} -> container:${CONTAINER_HEALTH_PORT})"

    if [ -n "${DOCKER_PLATFORM}" ]; then
        docker run -d \
            --name "${CONTAINER_NAME}" \
            --platform "${DOCKER_PLATFORM}" \
            -p "${HOST_PORT}:${CONTAINER_HEALTH_PORT}" \
            -e "TELEMETRY_INTERVAL=${TELEMETRY_INTERVAL}" \
            -e "VEHICLE_IDS=${VEHICLE_IDS}" \
            -e "ANOMALY_CPU_SPIKE_PROB=${ANOMALY_CPU_SPIKE_PROB}" \
            -e "ANOMALY_MEMORY_LEAK_PROB=${ANOMALY_MEMORY_LEAK_PROB}" \
            -e "ANOMALY_CORRUPT_JSON_PROB=${ANOMALY_CORRUPT_JSON_PROB}" \
            -e "HEALTH_PORT=${CONTAINER_HEALTH_PORT}" \
            "${FULL_IMAGE}" >/dev/null
    else
        docker run -d \
            --name "${CONTAINER_NAME}" \
            -p "${HOST_PORT}:${CONTAINER_HEALTH_PORT}" \
            -e "TELEMETRY_INTERVAL=${TELEMETRY_INTERVAL}" \
            -e "VEHICLE_IDS=${VEHICLE_IDS}" \
            -e "ANOMALY_CPU_SPIKE_PROB=${ANOMALY_CPU_SPIKE_PROB}" \
            -e "ANOMALY_MEMORY_LEAK_PROB=${ANOMALY_MEMORY_LEAK_PROB}" \
            -e "ANOMALY_CORRUPT_JSON_PROB=${ANOMALY_CORRUPT_JSON_PROB}" \
            -e "HEALTH_PORT=${CONTAINER_HEALTH_PORT}" \
            "${FULL_IMAGE}" >/dev/null
    fi

    log_info "Container ${CONTAINER_NAME} started successfully"
    log_info "Health endpoint: http://localhost:${HOST_PORT}/health"
    log_info "Follow logs: docker logs -f ${CONTAINER_NAME}"
}

print_status() {
    log_info "Project root: ${PROJECT_ROOT}"
    log_info "Image: ${FULL_IMAGE}"

    if image_exists; then
        log_info "Image status: present"
    else
        log_warn "Image status: not built"
    fi

    if container_is_running; then
        log_info "Container status: running"
        docker ps --filter "name=^/${CONTAINER_NAME}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
    elif container_exists; then
        log_warn "Container status: stopped"
        docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format 'table {{.Names}}\t{{.Status}}'
    else
        log_info "Container status: not deployed"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    case "${ACTION}" in
        stop)
            require_command docker
            check_docker_daemon
            stop_stack
            ;;
        status)
            require_command docker
            check_docker_daemon
            print_status
            ;;
        deploy)
            check_docker_daemon
            ensure_directories
            deploy_stack
            ;;
        *)
            die "Unknown action: ${ACTION}"
            ;;
    esac
}

main "$@"
