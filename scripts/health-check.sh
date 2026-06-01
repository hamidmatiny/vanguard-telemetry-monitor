#!/usr/bin/env bash
# health-check.sh — Cron-ready triage and automated recovery for Vanguard telemetry.
# Queries /health, inspects docker stats, and cold-restarts on sustained failure.

set -e
set -u
set -o pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

readonly SCRIPT_NAME="health-check"
readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy-factory.sh"

readonly CONTAINER_NAME="vanguard-telemetry"

readonly RUNTIME_DIR="${PROJECT_ROOT}/.runtime"
readonly STATE_FILE="${RUNTIME_DIR}/health-check.state"
readonly INCIDENT_LOG="${RUNTIME_DIR}/incidents.log"

# Thresholds (override via environment)
HOST_PORT="${HOST_PORT:-8080}"
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:${HOST_PORT}/health}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-5}"
CURL_MAX_TIME="${CURL_MAX_TIME:-10}"
MAX_CONSECUTIVE_FAILURES="${MAX_CONSECUTIVE_FAILURES:-3}"
CPU_CEILING_PERCENT="${CPU_CEILING_PERCENT:-90}"
MEM_CEILING_PERCENT="${MEM_CEILING_PERCENT:-85}"
RECOVERY_COOLDOWN_SECONDS="${RECOVERY_COOLDOWN_SECONDS:-30}"

DRY_RUN=0
VERBOSE=0

TEMP_FILES=()

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

_log() {
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

Automated health triage and recovery for the Vanguard telemetry container.
Designed for cron/systemd timer execution on macOS, Linux, or Windows (Git Bash).

Options:
  --help                      Show this help message and exit
  --dry-run                   Evaluate checks but do not restart the container
  --verbose                   Emit detailed diagnostic output
  --port PORT                 Host port for health endpoint (default: 8080)
  --max-failures N            Consecutive failures before recovery (default: 3)
  --cpu-ceiling PCT           CPU utilization ceiling (default: 90)
  --mem-ceiling PCT           Memory utilization ceiling (default: 85)

Environment variables:
  HOST_PORT, HEALTH_URL, CURL_CONNECT_TIMEOUT, CURL_MAX_TIME,
  MAX_CONSECUTIVE_FAILURES, CPU_CEILING_PERCENT, MEM_CEILING_PERCENT,
  RECOVERY_COOLDOWN_SECONDS

State files:
  ${STATE_FILE}
  ${INCIDENT_LOG}

Cron example (macOS/Linux):
  */2 * * * * ${SCRIPT_DIR}/${SCRIPT_NAME}.sh >> ${RUNTIME_DIR}/health-check.log 2>&1

EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --verbose)
                VERBOSE=1
                ;;
            --port)
                [ "$#" -ge 2 ] || die "Missing value for --port"
                HOST_PORT="$2"
                HEALTH_URL="http://127.0.0.1:${HOST_PORT}/health"
                shift
                ;;
            --max-failures)
                [ "$#" -ge 2 ] || die "Missing value for --max-failures"
                MAX_CONSECUTIVE_FAILURES="$2"
                shift
                ;;
            --cpu-ceiling)
                [ "$#" -ge 2 ] || die "Missing value for --cpu-ceiling"
                CPU_CEILING_PERCENT="$2"
                shift
                ;;
            --mem-ceiling)
                [ "$#" -ge 2 ] || die "Missing value for --mem-ceiling"
                MEM_CEILING_PERCENT="$2"
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
# State management
# ---------------------------------------------------------------------------

ensure_runtime_dir() {
    mkdir -p "${RUNTIME_DIR}"
}

read_failure_count() {
    if [ -f "${STATE_FILE}" ]; then
        awk -F= '/^failures=/ { print $2; exit }' "${STATE_FILE}" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

read_last_recovery_epoch() {
    if [ -f "${STATE_FILE}" ]; then
        awk -F= '/^last_recovery=/ { print $2; exit }' "${STATE_FILE}" 2>/dev/null || echo "0"
    else
        echo "0"
    fi
}

write_state() {
    local failures="$1"
    local last_recovery="$2"

    ensure_runtime_dir
    cat > "${STATE_FILE}" <<EOF
failures=${failures}
last_recovery=${last_recovery}
updated_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
EOF
}

reset_failure_count() {
    local last_recovery
    last_recovery="$(read_last_recovery_epoch)"
    write_state "0" "${last_recovery}"
}

increment_failure_count() {
    local current last_recovery
    current="$(read_failure_count)"
    last_recovery="$(read_last_recovery_epoch)"
    current=$((current + 1))
    write_state "${current}" "${last_recovery}"
    echo "${current}"
}

log_incident() {
    local reason="$1"
    ensure_runtime_dir
    printf '[%s] INCIDENT container=%s reason=%s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" "${CONTAINER_NAME}" "${reason}" \
        >> "${INCIDENT_LOG}"
}

# ---------------------------------------------------------------------------
# Preconditions
# ---------------------------------------------------------------------------

require_command() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: ${cmd}"
}

check_prerequisites() {
    require_command docker
    require_command curl
    require_command awk

    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon is not running"
    fi

    if [ ! -x "${DEPLOY_SCRIPT}" ]; then
        die "Deploy script not executable: ${DEPLOY_SCRIPT}"
    fi

    ensure_runtime_dir
}

container_is_running() {
    docker ps --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}' 2>/dev/null \
        | grep -qx "${CONTAINER_NAME}"
}

# ---------------------------------------------------------------------------
# Health and resource probes
# ---------------------------------------------------------------------------

check_http_health() {
    local response_file http_code

    response_file="$(mktemp "${RUNTIME_DIR}/health-response.XXXXXX")"
    register_temp_file "${response_file}"

    http_code="$(curl \
        --silent \
        --show-error \
        --connect-timeout "${CURL_CONNECT_TIMEOUT}" \
        --max-time "${CURL_MAX_TIME}" \
        --write-out '%{http_code}' \
        --output "${response_file}" \
        "${HEALTH_URL}" 2>/dev/null || printf '000')"

    if [ "${VERBOSE}" -eq 1 ]; then
        log_info "HTTP probe url=${HEALTH_URL} code=${http_code}"
        if [ -s "${response_file}" ]; then
            log_info "HTTP body: $(tr -d '\n' < "${response_file}")"
        fi
    fi

    if [ "${http_code}" != "200" ]; then
        log_warn "Health endpoint unreachable or unhealthy (HTTP ${http_code})"
        return 1
    fi

    if ! grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' "${response_file}" 2>/dev/null; then
        log_warn "Health payload missing status=ok"
        return 1
    fi

    log_info "Health endpoint responded OK"
    return 0
}

strip_percent() {
    # Input: "90.00%" -> "90.00"
    local value="$1"
    printf '%s' "${value}" | tr -d '%'
}

float_ge() {
    # Returns 0 if $1 >= $2 (bc-free awk comparison)
    awk -v a="$1" -v b="$2" 'BEGIN { exit (a + 0 >= b + 0) ? 0 : 1 }'
}

check_resource_utilization() {
    local stats_line cpu_raw mem_raw cpu_pct mem_pct

    if ! container_is_running; then
        log_warn "Container ${CONTAINER_NAME} is not running"
        return 1
    fi

    stats_line="$(docker stats "${CONTAINER_NAME}" --no-stream \
        --format '{{.CPUPerc}} {{.MemPerc}}' 2>/dev/null || true)"

    if [ -z "${stats_line}" ]; then
        log_warn "Unable to collect docker stats for ${CONTAINER_NAME}"
        return 1
    fi

    cpu_raw="$(printf '%s' "${stats_line}" | awk '{ print $1 }')"
    mem_raw="$(printf '%s' "${stats_line}" | awk '{ print $2 }')"
    cpu_pct="$(strip_percent "${cpu_raw}")"
    mem_pct="$(strip_percent "${mem_raw}")"

    if [ "${VERBOSE}" -eq 1 ]; then
        log_info "Resource snapshot cpu=${cpu_pct}% mem=${mem_pct}%"
    else
        log_info "Resource utilization cpu=${cpu_pct}% mem=${mem_pct}%"
    fi

    if float_ge "${cpu_pct}" "${CPU_CEILING_PERCENT}"; then
        log_warn "CPU ceiling exceeded (${cpu_pct}% >= ${CPU_CEILING_PERCENT}%) — possible anomaly deadlock"
        return 2
    fi

    if float_ge "${mem_pct}" "${MEM_CEILING_PERCENT}"; then
        log_warn "Memory ceiling exceeded (${mem_pct}% >= ${MEM_CEILING_PERCENT}%) — possible memory leak"
        return 2
    fi

    return 0
}

inspect_container_state() {
    local status health

    if ! container_is_running; then
        log_warn "Container ${CONTAINER_NAME} is not running"
        return 1
    fi

    status="$(docker inspect --format '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || true)"
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
        "${CONTAINER_NAME}" 2>/dev/null || true)"

    log_info "Container inspect status=${status} health=${health}"

    if [ "${status}" != "running" ]; then
        return 1
    fi

    if [ "${health}" = "unhealthy" ]; then
        log_warn "Docker HEALTHCHECK reports unhealthy"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Recovery
# ---------------------------------------------------------------------------

in_recovery_cooldown() {
    local last_recovery now elapsed
    last_recovery="$(read_last_recovery_epoch)"
    now="$(date +%s)"
    elapsed=$((now - last_recovery))

    if [ "${last_recovery}" -gt 0 ] && [ "${elapsed}" -lt "${RECOVERY_COOLDOWN_SECONDS}" ]; then
        log_warn "Recovery cooldown active (${elapsed}s / ${RECOVERY_COOLDOWN_SECONDS}s)"
        return 0
    fi

    return 1
}

perform_cold_restart() {
    local reason="$1"

    log_incident "${reason}"

    if [ "${DRY_RUN}" -eq 1 ]; then
        log_warn "Dry-run: would cold-restart ${CONTAINER_NAME} (${reason})"
        return 0
    fi

    if in_recovery_cooldown; then
        log_warn "Skipping recovery due to cooldown window"
        return 0
    fi

    log_error "Initiating cold restart for ${CONTAINER_NAME}: ${reason}"

    "${DEPLOY_SCRIPT}" --stop
    sleep 2
    "${DEPLOY_SCRIPT}" --port "${HOST_PORT}"

    write_state "0" "$(date +%s)"
    log_info "Cold restart completed for ${CONTAINER_NAME}"
}

# ---------------------------------------------------------------------------
# Triage orchestration
# ---------------------------------------------------------------------------

run_triage() {
    local http_ok=0 resource_ok=0 inspect_ok=0
    local resource_rc=0 failure_count=0
    local recovery_reason=""

    if ! container_is_running; then
        failure_count="$(increment_failure_count)"
        log_warn "Consecutive failures: ${failure_count}/${MAX_CONSECUTIVE_FAILURES}"

        if [ "${failure_count}" -ge "${MAX_CONSECUTIVE_FAILURES}" ]; then
            perform_cold_restart "container not running after ${failure_count} consecutive checks"
        fi
        return 1
    fi

    if inspect_container_state; then
        inspect_ok=1
    fi

    if check_http_health; then
        http_ok=1
    fi

    set +e
    check_resource_utilization
    resource_rc=$?
    set -e

    if [ "${resource_rc}" -eq 0 ]; then
        resource_ok=1
    fi

    if [ "${http_ok}" -eq 1 ] && [ "${resource_ok}" -eq 1 ] && [ "${inspect_ok}" -eq 1 ]; then
        reset_failure_count
        log_info "Triage passed — system healthy"
        return 0
    fi

    failure_count="$(increment_failure_count)"
    log_warn "Consecutive failures: ${failure_count}/${MAX_CONSECUTIVE_FAILURES}"

    if [ "${resource_rc}" -eq 2 ]; then
        recovery_reason="resource ceiling exceeded"
    elif [ "${http_ok}" -eq 0 ]; then
        recovery_reason="health endpoint failed ${failure_count} consecutive checks"
    elif [ "${inspect_ok}" -eq 0 ]; then
        recovery_reason="container inspect reported unhealthy state"
    else
        recovery_reason="composite health check failure"
    fi

    if [ "${failure_count}" -ge "${MAX_CONSECUTIVE_FAILURES}" ] || [ "${resource_rc}" -eq 2 ]; then
        perform_cold_restart "${recovery_reason}"
        return 1
    fi

    log_warn "Recovery deferred — awaiting ${MAX_CONSECUTIVE_FAILURES} consecutive failures"
    return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    check_prerequisites
    run_triage
}

main "$@"
