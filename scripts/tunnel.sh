#!/bin/bash
# =============================================================================
# tunnel.sh — Start / Stop / Restart the cloudflared tunnel daemon.
# Run every development session.
#
# Usage:  bash scripts/tunnel.sh {start|stop|restart|status|logs}
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
fatal()   { error "$*"; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}\n${BOLD}${CYAN}  $*${RESET}\n${BOLD}${CYAN}══════════════════════════════════════════${RESET}\n"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cloudflare.config.sh"

tunnel_is_running() {
    [[ -f "$CF_TUNNEL_PID_FILE" ]] && kill -0 "$(cat "$CF_TUNNEL_PID_FILE")" 2>/dev/null && return 0
    pgrep -f "cloudflared.*${CF_TUNNEL_NAME}" &>/dev/null && return 0
    return 1
}

wait_for_connection() {
    local MAX=45 ELAPSED=0
    info "Waiting up to ${MAX}s for tunnel connection..."
    while [[ $ELAPSED -lt $MAX ]]; do
        if grep -qE "Connection .* registered|Registered tunnel connection|INF Connection" "$CF_TUNNEL_LOG_FILE" 2>/dev/null; then
            return 0
        fi
        sleep 2; (( ELAPSED += 2 )) || true; echo -n "."
    done
    echo ""; return 1
}

url_reachable() {
    local CODE; CODE="$(curl -sSo /dev/null -w '%{http_code}' --max-time 8 "$1" 2>/dev/null || echo "000")"
    case "$CODE" in 2*|3*|401|403) return 0 ;; *) return 1 ;; esac
}

cmd_start() {
    banner "Starting Colony Tunnel — ${CF_TUNNEL_NAME}"
    command -v cloudflared &>/dev/null || fatal "cloudflared not installed. Run: bash scripts/cloudflare-setup.sh"
    [[ -f "$CF_TUNNEL_CREDENTIALS_FILE" ]] || fatal "No credentials. Run: bash scripts/cloudflare-setup.sh"
    [[ -f "$CF_TUNNEL_CONFIG_FILE" ]]      || fatal "No config. Run: bash scripts/cloudflare-setup.sh"

    if tunnel_is_running; then
        warn "Tunnel already running. Use 'restart' to restart."
        cmd_status; exit 0
    fi

    : > "$CF_TUNNEL_LOG_FILE"
    echo "stopped" > "$CF_TUNNEL_STATUS_FILE"

    cloudflared tunnel \
        --config "$CF_TUNNEL_CONFIG_FILE" \
        --logfile "$CF_TUNNEL_LOG_FILE" \
        --loglevel info \
        run "${CF_TUNNEL_NAME}" &

    DAEMON_PID=$!
    echo "$DAEMON_PID" > "$CF_TUNNEL_PID_FILE"
    info "Daemon PID: ${DAEMON_PID}"

    if wait_for_connection; then
        echo "running" > "$CF_TUNNEL_STATUS_FILE"
        success "Tunnel connected!"
    else
        warn "Tunnel still connecting — check logs: bash scripts/tunnel.sh logs"
        echo "connecting" > "$CF_TUNNEL_STATUS_FILE"
    fi

    echo ""
    info "Testing endpoint reachability..."
    ENDPOINTS=("$CF_API_URL" "$CF_ADMIN_URL" "$CF_STUDIO_URL" "$CF_COOLIFY_URL")
    LABELS=("API" "Admin" "Studio" "Coolify")
    ALL_OK=true
    for i in "${!ENDPOINTS[@]}"; do
        if url_reachable "${ENDPOINTS[$i]}"; then
            echo -e "  ${GREEN}✓${RESET}  ${LABELS[$i]}: ${CYAN}${ENDPOINTS[$i]}${RESET}"
        else
            echo -e "  ${YELLOW}~${RESET}  ${LABELS[$i]}: ${CYAN}${ENDPOINTS[$i]}${RESET}  ${YELLOW}(service offline or DNS propagating)${RESET}"
            ALL_OK=false
        fi
    done

    echo ""
    echo -e "${BOLD}Permanent URLs:${RESET}"
    echo -e "  API:     ${CYAN}${CF_API_URL}${RESET}"
    echo -e "  Admin:   ${CYAN}${CF_ADMIN_URL}${RESET}"
    echo -e "  Studio:  ${CYAN}${CF_STUDIO_URL}${RESET}"
    echo -e "  Coolify: ${CYAN}${CF_COOLIFY_URL}${RESET}"
    echo ""
    echo -e "${YELLOW}Stop:${RESET} bash scripts/tunnel.sh stop"
    echo -e "${YELLOW}Logs:${RESET} bash scripts/tunnel.sh logs"
}

cmd_stop() {
    banner "Stopping Colony Tunnel"
    if ! tunnel_is_running; then warn "Tunnel not running."; echo "stopped" > "$CF_TUNNEL_STATUS_FILE"; return 0; fi
    if [[ -f "$CF_TUNNEL_PID_FILE" ]]; then
        PID="$(cat "$CF_TUNNEL_PID_FILE")"
        kill "$PID" 2>/dev/null || true; sleep 2
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
        rm -f "$CF_TUNNEL_PID_FILE"
    fi
    pkill -f "cloudflared.*${CF_TUNNEL_NAME}" 2>/dev/null || true
    echo "stopped" > "$CF_TUNNEL_STATUS_FILE"
    success "Tunnel stopped."
}

cmd_restart() { cmd_stop; sleep 1; cmd_start; }

cmd_status() {
    echo ""
    echo -e "${BOLD}Daemon:${RESET}"
    if tunnel_is_running; then
        PID="$(cat "$CF_TUNNEL_PID_FILE" 2>/dev/null || pgrep -f "cloudflared.*${CF_TUNNEL_NAME}" | head -1 || echo '?')"
        echo -e "  ${GREEN}● Running${RESET} (PID ${PID})"
    else
        echo -e "  ${RED}● Stopped${RESET}"
    fi
    echo ""
    echo -e "${BOLD}Endpoints:${RESET}"
    ENDPOINTS=("$CF_API_URL" "$CF_ADMIN_URL" "$CF_STUDIO_URL" "$CF_COOLIFY_URL")
    LABELS=("API    " "Admin  " "Studio " "Coolify")
    for i in "${!ENDPOINTS[@]}"; do
        url_reachable "${ENDPOINTS[$i]}" \
            && echo -e "  ${GREEN}✓${RESET}  ${LABELS[$i]}  ${CYAN}${ENDPOINTS[$i]}${RESET}" \
            || echo -e "  ${RED}✗${RESET}  ${LABELS[$i]}  ${CYAN}${ENDPOINTS[$i]}${RESET}"
    done
    echo ""
}

cmd_logs() {
    [[ -f "$CF_TUNNEL_LOG_FILE" ]] && tail -f "$CF_TUNNEL_LOG_FILE" || warn "Log not found. Has the tunnel started?"
}

COMMAND="${1:-start}"
case "$COMMAND" in
    start)   cmd_start   ;;
    stop)    cmd_stop    ;;
    restart) cmd_restart ;;
    status)  cmd_status  ;;
    logs)    cmd_logs    ;;
    *) echo "Usage: bash scripts/tunnel.sh {start|stop|restart|status|logs}"; exit 1 ;;
esac
