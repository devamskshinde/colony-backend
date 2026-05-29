#!/bin/bash
# =============================================================================
# colony.sh — Colony Session Manager & Recovery Tool
#
# ONE script replaces: tunnel.sh + tunnel-status.sh + find-wsl-ip.sh
# Also adds: interactive tunnel selection, git sync, and health check.
#
# Usage:
#   bash scripts/colony.sh start              # Start dev session (interactive tunnel selection)
#   bash scripts/colony.sh start --cloudflare # Start Cloudflare tunnel (skip prompt)
#   bash scripts/colony.sh start --direct     # Start with direct IP (skip prompt)
#   bash scripts/colony.sh start --tailscale  # Start with Tailscale (skip prompt)
#   bash scripts/colony.sh stop               # Stop tunnel daemon
#   bash scripts/colony.sh restart            # Stop then start
#   bash scripts/colony.sh status             # Full visual health check
#   bash scripts/colony.sh logs               # Tail Cloudflare tunnel logs
#   bash scripts/colony.sh sync "msg"         # Git commit + push to both repos
#   bash scripts/colony.sh ip                 # Print all WSL/public/Tailscale IPs
# =============================================================================

set -euo pipefail

# ── Colours & helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
fatal()   { error "$*"; exit 1; }
banner()  {
    echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║  $*${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}\n"
}
section() { echo -e "\n${BOLD}${CYAN}── $* ──────────────────────────────────${RESET}"; }

# ── Paths & config ─────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"
REPO_DIR="$(dirname "$BACKEND_DIR")"
CONFIG_FILE="${SCRIPT_DIR}/cloudflare.config.sh"
SUPABASE_DIR="${BACKEND_DIR}/docker/supabase"

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" || {
    warn "cloudflare.config.sh not found — Cloudflare features unavailable."
}

# ── Network helpers ────────────────────────────────────────────────────────────
get_wsl_ip() {
    local IP
    IP="$(hostname -I 2>/dev/null | awk '{print $1}' | tr -d '[:space:]')"
    [[ -n "$IP" && "$IP" != "127.0.0.1" ]] && echo "$IP" && return

    IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[\d.]+' | head -1 || true)"
    [[ -n "$IP" ]] && echo "$IP" && return

    IP="$(ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d'/' -f1 | head -1 || true)"
    [[ -n "$IP" ]] && echo "$IP" && return

    echo "127.0.0.1"
}

get_public_ip() {
    curl -sSf --max-time 5 https://api.ipify.org 2>/dev/null \
    || curl -sSf --max-time 5 https://icanhazip.com 2>/dev/null \
    || echo "unavailable"
}

get_tailscale_ip() {
    if command -v tailscale &>/dev/null; then
        tailscale ip --4 2>/dev/null || echo "not-connected"
    else
        echo "not-installed"
    fi
}

# ── Docker helpers ─────────────────────────────────────────────────────────────
ensure_docker() {
    if docker info &>/dev/null 2>&1; then
        return 0
    fi
    warn "Docker not running — attempting to start..."
    sudo service docker start 2>/dev/null || sudo dockerd &>/tmp/dockerd.log &
    sleep 5
    docker info &>/dev/null || fatal "Docker could not be started. Run: sudo service docker start"
    success "Docker started."
}

# ── Supabase helpers ───────────────────────────────────────────────────────────
ensure_supabase() {
    if ! docker ps 2>/dev/null | grep -q "colony-db"; then
        warn "Supabase containers not running — starting..."
        local ENV_FILE="${SUPABASE_DIR}/.env.supabase"
        if [[ -f "${SUPABASE_DIR}/docker-compose.yml" && -f "$ENV_FILE" ]]; then
            docker compose -f "${SUPABASE_DIR}/docker-compose.yml" --env-file "$ENV_FILE" up -d
            success "Supabase containers started."
        else
            warn "Supabase compose files not found — skipping Supabase startup."
        fi
    else
        success "Supabase containers already running."
    fi
}

# ── Cloudflare tunnel helpers ─────────────────────────────────────────────────
tunnel_is_running() {
    [[ -f "${CF_TUNNEL_PID_FILE:-/tmp/cloudflared-dummy.pid}" ]] \
        && kill -0 "$(cat "${CF_TUNNEL_PID_FILE}")" 2>/dev/null && return 0
    pgrep -f "cloudflared.*${CF_TUNNEL_NAME:-colony-dev}" &>/dev/null && return 0
    return 1
}

wait_for_tunnel_connection() {
    local MAX=45 ELAPSED=0
    info "Waiting up to ${MAX}s for tunnel to connect..."
    while [[ $ELAPSED -lt $MAX ]]; do
        if grep -qE "Connection .* registered|Registered tunnel connection|INF Connection" \
            "${CF_TUNNEL_LOG_FILE:-/tmp/cloudflared-dummy.log}" 2>/dev/null; then
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

url_check_verbose() {
    local URL="$1" LABEL="$2"
    local RESULT; RESULT="$(curl -sSo /dev/null -w '%{http_code} %{time_total}' --max-time 10 "$URL" 2>/dev/null || echo "000 0")"
    local CODE; CODE="$(echo "$RESULT" | awk '{print $1}')"
    local MS; MS="$(echo "$RESULT" | awk '{printf "%.0f", $2*1000}')"
    case "$CODE" in
        2*|3*|401|403)
            echo -e "  ${GREEN}✓${RESET}  ${BOLD}${LABEL}${RESET}  ${CYAN}${URL}${RESET}"
            echo -e "      HTTP ${GREEN}${CODE}${RESET}  |  ${MS}ms"
            return 0 ;;
        000)
            echo -e "  ${RED}✗${RESET}  ${BOLD}${LABEL}${RESET}  ${CYAN}${URL}${RESET}"
            echo -e "      ${RED}Connection failed${RESET} — tunnel down or DNS unresolved"
            return 1 ;;
        *)
            echo -e "  ${YELLOW}~${RESET}  ${BOLD}${LABEL}${RESET}  ${CYAN}${URL}${RESET}"
            echo -e "      HTTP ${YELLOW}${CODE}${RESET}  |  ${MS}ms  (service responding with error)"
            return 0 ;;
    esac
}

# ── .env.local update ─────────────────────────────────────────────────────────
update_env_local() {
    local WSL_IP="$1" PUBLIC_IP="$2" TAILSCALE_IP="$3"
    local ENV_LOCAL="${BACKEND_DIR}/.env.local"

    cat > "$ENV_LOCAL" <<ENVEOF
# .env.local — auto-generated by colony.sh
# DO NOT manually edit — regenerated each WSL session.
# For permanent public URLs, use .env.tunnel

WSL_IP=${WSL_IP}
PUBLIC_IP=${PUBLIC_IP}
TAILSCALE_IP=${TAILSCALE_IP}

COOLIFY_LOCAL=http://${WSL_IP}:${LOCAL_PORT_COOLIFY:-8000}
STUDIO_LOCAL=http://${WSL_IP}:${LOCAL_PORT_STUDIO:-3002}
SUPABASE_API_LOCAL=http://${WSL_IP}:${LOCAL_PORT_SUPABASE:-8001}
API_LOCAL=http://${WSL_IP}:${LOCAL_PORT_API:-3000}
ADMIN_LOCAL=http://${WSL_IP}:${LOCAL_PORT_ADMIN:-3001}
ENVEOF
    success ".env.local updated."
}

# =============================================================================
# START COMMAND
# =============================================================================

start_cloudflare_tunnel() {
    banner "Starting Colony — Cloudflare Tunnel"

    command -v cloudflared &>/dev/null \
        || fatal "cloudflared not installed. Run: bash scripts/colony-setup.sh --cloudflare"
    [[ -f "${CF_TUNNEL_CREDENTIALS_FILE:-}" ]] \
        || fatal "No tunnel credentials. Run: bash scripts/colony-setup.sh --cloudflare"
    [[ -f "${CF_TUNNEL_CONFIG_FILE:-}" ]] \
        || fatal "No tunnel config. Run: bash scripts/colony-setup.sh --cloudflare"

    if tunnel_is_running; then
        warn "Tunnel already running. Showing status..."
        cmd_status; return 0
    fi

    : > "${CF_TUNNEL_LOG_FILE}"
    echo "stopped" > "${CF_TUNNEL_STATUS_FILE}"

    cloudflared tunnel \
        --config "${CF_TUNNEL_CONFIG_FILE}" \
        --logfile "${CF_TUNNEL_LOG_FILE}" \
        --loglevel info \
        run "${CF_TUNNEL_NAME}" &

    local DAEMON_PID=$!
    echo "$DAEMON_PID" > "${CF_TUNNEL_PID_FILE}"
    info "Tunnel daemon PID: ${DAEMON_PID}"

    if wait_for_tunnel_connection; then
        echo "running" > "${CF_TUNNEL_STATUS_FILE}"
        success "Tunnel connected!"
    else
        warn "Tunnel still connecting — check logs: bash scripts/colony.sh logs"
        echo "connecting" > "${CF_TUNNEL_STATUS_FILE}"
    fi

    echo ""
    info "Testing endpoint reachability..."
    local ENDPOINTS=("${CF_API_URL:-}" "${CF_ADMIN_URL:-}" "${CF_STUDIO_URL:-}" "${CF_COOLIFY_URL:-}")
    local LABELS=("API" "Admin" "Studio" "Coolify")
    for i in "${!ENDPOINTS[@]}"; do
        [[ -z "${ENDPOINTS[$i]}" ]] && continue
        if url_reachable "${ENDPOINTS[$i]}"; then
            echo -e "  ${GREEN}✓${RESET}  ${LABELS[$i]}: ${CYAN}${ENDPOINTS[$i]}${RESET}"
        else
            echo -e "  ${YELLOW}~${RESET}  ${LABELS[$i]}: ${CYAN}${ENDPOINTS[$i]}${RESET}  ${YELLOW}(DNS propagating or service offline)${RESET}"
        fi
    done

    echo ""
    echo -e "${BOLD}Permanent Public URLs:${RESET}"
    echo -e "  API:     ${CYAN}${CF_API_URL:-N/A}${RESET}"
    echo -e "  Admin:   ${CYAN}${CF_ADMIN_URL:-N/A}${RESET}"
    echo -e "  Studio:  ${CYAN}${CF_STUDIO_URL:-N/A}${RESET}"
    echo -e "  Coolify: ${CYAN}${CF_COOLIFY_URL:-N/A}${RESET}"
    echo ""
    echo -e "${YELLOW}Stop:${RESET}  bash scripts/colony.sh stop"
    echo -e "${YELLOW}Logs:${RESET}  bash scripts/colony.sh logs"
}

start_direct_ip() {
    banner "Starting Colony — Direct Public IP"

    local WSL_IP PUBLIC_IP
    WSL_IP="$(get_wsl_ip)"
    PUBLIC_IP="$(get_public_ip)"

    echo -e "${BOLD}Your connection details:${RESET}"
    echo -e "  WSL IP:    ${CYAN}${WSL_IP}${RESET}  (local — for testing on same machine)"
    echo -e "  Public IP: ${CYAN}${PUBLIC_IP}${RESET}  (your router's external IP)"
    echo ""
    echo -e "${BOLD}Local service URLs:${RESET}"
    echo -e "  API:             http://${WSL_IP}:${LOCAL_PORT_API:-3000}"
    echo -e "  Supabase Studio: http://${WSL_IP}:${LOCAL_PORT_STUDIO:-3002}"
    echo -e "  Supabase API:    http://${WSL_IP}:${LOCAL_PORT_SUPABASE:-8001}"
    echo -e "  Coolify:         http://${WSL_IP}:${LOCAL_PORT_COOLIFY:-8000}"
    echo ""
    echo -e "${YELLOW}⚠ Note:${RESET} The WSL IP changes on every WSL restart."
    echo -e "  Run ${YELLOW}bash scripts/colony.sh ip${RESET} after each restart to get the new IP."
    echo ""
    echo -e "${BOLD}Firewall reminder:${RESET}"
    echo -e "  Ensure ports ${LOCAL_PORT_API:-3000}, ${LOCAL_PORT_STUDIO:-3002}, ${LOCAL_PORT_COOLIFY:-8000} are forwarded"
    echo -e "  in your Windows Firewall / router for external access."
}

start_tailscale() {
    banner "Starting Colony — Tailscale"

    if ! command -v tailscale &>/dev/null; then
        fatal "Tailscale not installed. Run: bash scripts/colony-setup.sh --tailscale"
    fi

    if ! tailscale status &>/dev/null 2>&1; then
        # Try to start daemon
        info "Starting tailscaled daemon..."
        sudo tailscaled \
            --state=/var/lib/tailscale/tailscaled.state \
            --socket=/run/tailscale/tailscaled.sock \
            &>/tmp/tailscaled.log &
        sleep 3
        tailscale status &>/dev/null 2>&1 \
            || fatal "tailscaled did not start. Check /tmp/tailscaled.log"
    fi

    local TSIP; TSIP="$(tailscale ip --4 2>/dev/null || echo '')"
    if [[ -z "$TSIP" ]]; then
        warn "Tailscale not authenticated — run: sudo tailscale up --accept-routes"
        fatal "Connect Tailscale first: bash scripts/colony-setup.sh --tailscale"
    fi

    success "Tailscale connected — IP: ${TSIP}"
    echo ""
    echo -e "${BOLD}Tailscale service URLs (stable, never change):${RESET}"
    echo -e "  API:             http://${TSIP}:${LOCAL_PORT_API:-3000}"
    echo -e "  Supabase Studio: http://${TSIP}:${LOCAL_PORT_STUDIO:-3002}"
    echo -e "  Supabase API:    http://${TSIP}:${LOCAL_PORT_SUPABASE:-8001}"
    echo -e "  Coolify:         http://${TSIP}:${LOCAL_PORT_COOLIFY:-8000}"
    echo ""
    echo -e "${GREEN}${BOLD}Tailscale IP never changes — use this in Flutter for device testing.${RESET}"
}

cmd_start() {
    local MODE="${1:-}"

    # ── Ensure Docker is up first ──────────────────────────────────────────────
    section "Pre-flight: Docker"
    ensure_docker

    # ── Ensure Supabase is up ──────────────────────────────────────────────────
    section "Pre-flight: Supabase"
    ensure_supabase

    # ── Detect and update WSL IP ───────────────────────────────────────────────
    section "Pre-flight: WSL Network"
    local WSL_IP PUBLIC_IP TAILSCALE_IP
    WSL_IP="$(get_wsl_ip)"
    PUBLIC_IP="$(get_public_ip)"
    TAILSCALE_IP="$(get_tailscale_ip)"

    # Check if IP changed since last session
    local PREV_IP=""
    [[ -f "${BACKEND_DIR}/.env.local" ]] && \
        PREV_IP="$(grep '^WSL_IP=' "${BACKEND_DIR}/.env.local" 2>/dev/null | cut -d= -f2 | tr -d '[:space:]' || true)"

    if [[ -n "$PREV_IP" && "$PREV_IP" != "$WSL_IP" ]]; then
        warn "WSL IP changed: ${PREV_IP} → ${WSL_IP} (WSL was restarted)"
    else
        success "WSL IP: ${WSL_IP}"
    fi

    update_env_local "$WSL_IP" "$PUBLIC_IP" "$TAILSCALE_IP"
    echo ""

    # ── Mode selection ─────────────────────────────────────────────────────────
    if [[ "$MODE" == "--cloudflare" || "$MODE" == "-c" ]]; then
        start_cloudflare_tunnel
        return 0
    elif [[ "$MODE" == "--direct" || "$MODE" == "-d" ]]; then
        start_direct_ip
        return 0
    elif [[ "$MODE" == "--tailscale" || "$MODE" == "-t" ]]; then
        start_tailscale
        return 0
    fi

    # ── Interactive tunnel selection (no flag given) ───────────────────────────
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║   Choose Your Connection Method              ║${RESET}"
    echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════╣${RESET}"
    echo -e "${BOLD}${CYAN}║  [1] Cloudflare Tunnel ${GREEN}(Recommended)${CYAN}         ║${RESET}"
    echo -e "${BOLD}${CYAN}║      Permanent URLs that never change        ║${RESET}"
    echo -e "${BOLD}${CYAN}║      Works across any network/NAT            ║${RESET}"
    echo -e "${BOLD}${CYAN}║                                              ║${RESET}"
    echo -e "${BOLD}${CYAN}║  [2] Direct Public IP                        ║${RESET}"
    echo -e "${BOLD}${CYAN}║      Use WSL IP directly (changes on restart)║${RESET}"
    echo -e "${BOLD}${CYAN}║      Good for same-machine testing           ║${RESET}"
    echo -e "${BOLD}${CYAN}║                                              ║${RESET}"
    echo -e "${BOLD}${CYAN}║  [3] Tailscale                               ║${RESET}"
    echo -e "${BOLD}${CYAN}║      Stable 100.x IP for device testing      ║${RESET}"
    echo -e "${BOLD}${CYAN}║      Requires Tailscale on all devices       ║${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}"
    echo ""

    local CHOICE
    read -rp "Enter choice [1/2/3] (default: 1): " CHOICE
    CHOICE="${CHOICE:-1}"

    case "$CHOICE" in
        1) start_cloudflare_tunnel ;;
        2) start_direct_ip ;;
        3) start_tailscale ;;
        *)
            warn "Invalid choice '${CHOICE}' — defaulting to Cloudflare Tunnel."
            start_cloudflare_tunnel ;;
    esac
}

# =============================================================================
# STOP COMMAND
# =============================================================================

cmd_stop() {
    banner "Stopping Colony Tunnel"

    if ! tunnel_is_running; then
        warn "Tunnel not running."
        [[ -n "${CF_TUNNEL_STATUS_FILE:-}" ]] && echo "stopped" > "${CF_TUNNEL_STATUS_FILE}" || true
        return 0
    fi

    if [[ -f "${CF_TUNNEL_PID_FILE:-}" ]]; then
        local PID; PID="$(cat "${CF_TUNNEL_PID_FILE}")"
        kill "$PID" 2>/dev/null || true
        sleep 2
        kill -0 "$PID" 2>/dev/null && kill -9 "$PID" 2>/dev/null || true
        rm -f "${CF_TUNNEL_PID_FILE}"
    fi

    pkill -f "cloudflared.*${CF_TUNNEL_NAME:-colony-dev}" 2>/dev/null || true
    [[ -n "${CF_TUNNEL_STATUS_FILE:-}" ]] && echo "stopped" > "${CF_TUNNEL_STATUS_FILE}" || true
    success "Tunnel stopped."
}

# =============================================================================
# STATUS COMMAND — Full visual health check
# =============================================================================

cmd_status() {
    local WSL_IP; WSL_IP="$(get_wsl_ip)"
    local PASS=0 FAIL=0 WARN=0

    check_pass() { echo -e "  ${GREEN}✓${RESET}  $*"; (( PASS++ )) || true; }
    check_fail() { echo -e "  ${RED}✗${RESET}  $*"; (( FAIL++ )) || true; }
    check_warn() { echo -e "  ${YELLOW}~${RESET}  $*"; (( WARN++ )) || true; }
    check_url_simple() {
        local URL="$1" LABEL="$2"
        local CODE; CODE="$(curl -sSo /dev/null -w '%{http_code}' --max-time 8 "$URL" 2>/dev/null || echo '000')"
        case "$CODE" in
            2*|3*|401|403) check_pass "${LABEL} (HTTP ${CODE})" ;;
            000)           check_fail "${LABEL} — connection refused" ;;
            *)             check_warn "${LABEL} — HTTP ${CODE}" ;;
        esac
    }

    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  Colony — Health Check  $(date)${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${RESET}"

    # ── Docker ─────────────────────────────────────────────────────────────────
    section "Docker"
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        check_pass "Docker Engine running ($(docker --version | head -1))"
    else
        check_fail "Docker not running — sudo service docker start"
    fi

    # ── Supabase containers ────────────────────────────────────────────────────
    section "Supabase Containers"
    declare -A EXPECTED=(
        ["colony-db"]="PostgreSQL"
        ["colony-kong"]="Kong API Gateway"
        ["colony-auth"]="Auth (GoTrue)"
        ["colony-rest"]="PostgREST"
        ["colony-realtime"]="Realtime"
        ["colony-storage"]="Storage"
        ["colony-studio"]="Supabase Studio"
    )
    for CONTAINER in "${!EXPECTED[@]}"; do
        local LABEL="${EXPECTED[$CONTAINER]}"
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
            check_fail "${LABEL} — container not running"
            continue
        fi
        local HEALTH; HEALTH="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
            "$CONTAINER" 2>/dev/null || echo 'inspect-failed')"
        case "$HEALTH" in
            healthy|no-healthcheck) check_pass "${LABEL}" ;;
            starting)  check_warn "${LABEL} — still starting up" ;;
            unhealthy) check_fail "${LABEL} — UNHEALTHY (docker logs ${CONTAINER})" ;;
            *)         check_warn "${LABEL} — ${HEALTH}" ;;
        esac
    done

    # ── PostgreSQL extensions ──────────────────────────────────────────────────
    section "PostgreSQL Extensions"
    if docker exec colony-db pg_isready -U postgres &>/dev/null 2>&1; then
        check_pass "PostgreSQL accepting connections"
        for EXT in postgis uuid-ossp pg_trgm pgcrypto; do
            local COUNT; COUNT="$(docker exec colony-db psql -U postgres -tAc \
                "SELECT COUNT(*) FROM pg_extension WHERE extname='${EXT}';" 2>/dev/null || echo '0')"
            [[ "$COUNT" == "1" ]] && check_pass "${EXT}" || check_warn "${EXT} — not installed"
        done
    else
        check_fail "PostgreSQL NOT accepting connections"
    fi

    # ── Local HTTP services ────────────────────────────────────────────────────
    section "Local HTTP Services"
    check_url_simple "http://${WSL_IP}:${LOCAL_PORT_STUDIO:-3002}"   "Supabase Studio"
    check_url_simple "http://${WSL_IP}:${LOCAL_PORT_SUPABASE:-8001}" "Supabase Kong API"
    check_url_simple "http://${WSL_IP}:${LOCAL_PORT_COOLIFY:-8000}"  "Coolify Dashboard"

    # ── Coolify containers ─────────────────────────────────────────────────────
    section "Coolify"
    if docker ps 2>/dev/null | grep -q "coolify"; then
        check_pass "Coolify container(s) running"
    else
        check_fail "Coolify not running — run: bash scripts/colony-setup.sh"
    fi

    # ── Cloudflare Tunnel ──────────────────────────────────────────────────────
    section "Cloudflare Tunnel"
    if tunnel_is_running; then
        local PID; PID="$(cat "${CF_TUNNEL_PID_FILE:-/dev/null}" 2>/dev/null \
            || pgrep -f "cloudflared.*${CF_TUNNEL_NAME:-colony-dev}" | head -1 || echo '?')"
        check_pass "cloudflared daemon running (PID ${PID})"
    else
        check_warn "Tunnel not running — start with: bash scripts/colony.sh start"
    fi

    [[ -f "${BACKEND_DIR}/.env.tunnel" ]] \
        && check_pass ".env.tunnel exists" \
        || check_fail ".env.tunnel missing — run: bash scripts/colony-setup.sh --cloudflare"

    if [[ -n "${CF_API_URL:-}" ]]; then
        check_url_simple "${CF_API_URL}"     "API endpoint (${CF_API_URL})"
        check_url_simple "${CF_STUDIO_URL}"  "Studio endpoint (${CF_STUDIO_URL})"
        check_url_simple "${CF_COOLIFY_URL}" "Coolify endpoint (${CF_COOLIFY_URL})"
    fi

    # ── Cloudflare API health ──────────────────────────────────────────────────
    if [[ -n "${CF_API_TOKEN:-}" && -n "${CF_ACCOUNT_ID:-}" ]]; then
        local CF_STATUS; CF_STATUS="$(curl -sSf \
            "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${CF_TUNNEL_NAME:-colony-dev}&is_deleted=false" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" 2>/dev/null \
            | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0].get('status','unknown') if r else 'not-found')" \
            2>/dev/null || echo "unknown")"
        case "$CF_STATUS" in
            healthy)   check_pass "Cloudflare API: tunnel healthy" ;;
            inactive)  check_warn "Cloudflare API: tunnel inactive (no active connections)" ;;
            degraded)  check_warn "Cloudflare API: tunnel degraded" ;;
            not-found) check_warn "Cloudflare API: tunnel not found — run colony-setup.sh --cloudflare" ;;
            *)         check_warn "Cloudflare API: status = ${CF_STATUS}" ;;
        esac
    fi

    # ── Tailscale ──────────────────────────────────────────────────────────────
    section "Tailscale (optional)"
    if ! command -v tailscale &>/dev/null; then
        check_warn "Not installed (optional — run: bash scripts/colony-setup.sh --tailscale)"
    else
        local TSIP; TSIP="$(tailscale ip --4 2>/dev/null || echo '')"
        if [[ -n "$TSIP" ]]; then
            check_pass "Connected — Tailscale IP: ${TSIP}"
        else
            check_warn "Installed but not connected — run: bash scripts/colony-setup.sh --tailscale"
        fi
    fi

    # ── Network info ───────────────────────────────────────────────────────────
    section "Network Info"
    echo -e "  WSL IP:       ${GREEN}${WSL_IP}${RESET}"
    echo -e "  Tailscale IP: ${CYAN}$(get_tailscale_ip)${RESET}"

    # ── Summary ────────────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}Colony Status Summary${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${RESET}"
    echo -e "  ${GREEN}✓ Passed:   ${PASS}${RESET}"
    echo -e "  ${YELLOW}~ Warnings: ${WARN}${RESET}"
    echo -e "  ${RED}✗ Failed:   ${FAIL}${RESET}"
    echo ""

    if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All checks passed — environment fully operational!${RESET}"
    elif [[ $FAIL -eq 0 ]]; then
        echo -e "${YELLOW}${BOLD}Minor warnings — environment usable, review warnings above.${RESET}"
    else
        echo -e "${RED}${BOLD}${FAIL} check(s) failed — investigate above.${RESET}"
        echo ""
        echo -e "${BOLD}Common fixes:${RESET}"
        echo -e "  Docker not running:   sudo service docker start"
        echo -e "  Supabase not running: bash scripts/colony.sh start"
        echo -e "  Coolify not running:  bash scripts/colony-setup.sh"
        echo -e "  Tunnel not running:   bash scripts/colony.sh start"
    fi
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${RESET}"
    echo ""

    [[ $FAIL -eq 0 ]] && exit 0 || exit 1
}

# =============================================================================
# LOGS COMMAND
# =============================================================================

cmd_logs() {
    local LOG="${CF_TUNNEL_LOG_FILE:-/tmp/cloudflared-colony-dev.log}"
    if [[ -f "$LOG" ]]; then
        info "Tailing: ${LOG}  (Ctrl+C to stop)"
        tail -f "$LOG"
    else
        warn "Log file not found. Has the tunnel started? Run: bash scripts/colony.sh start"
    fi
}

# =============================================================================
# IP COMMAND — Print all network addresses
# =============================================================================

cmd_ip() {
    local WSL_IP PUBLIC_IP TAILSCALE_IP
    WSL_IP="$(get_wsl_ip)"
    PUBLIC_IP="$(get_public_ip)"
    TAILSCALE_IP="$(get_tailscale_ip)"

    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  Colony — Network Information${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${RESET}"
    echo ""
    echo -e "${BOLD}Addresses:${RESET}"
    echo -e "  WSL IP:       ${GREEN}${WSL_IP}${RESET}  (local, changes on WSL restart)"
    echo -e "  Public IP:    ${CYAN}${PUBLIC_IP}${RESET}  (your router's external IP)"
    echo -e "  Tailscale IP: ${CYAN}${TAILSCALE_IP}${RESET}  (stable, never changes)"
    echo ""
    echo -e "${BOLD}Local service URLs:${RESET}"
    echo -e "  API:             http://${WSL_IP}:${LOCAL_PORT_API:-3000}"
    echo -e "  Supabase Studio: http://${WSL_IP}:${LOCAL_PORT_STUDIO:-3002}"
    echo -e "  Supabase API:    http://${WSL_IP}:${LOCAL_PORT_SUPABASE:-8001}"
    echo -e "  Coolify:         http://${WSL_IP}:${LOCAL_PORT_COOLIFY:-8000}"

    if [[ -f "${BACKEND_DIR}/.env.tunnel" ]]; then
        # shellcheck source=/dev/null
        source "${BACKEND_DIR}/.env.tunnel"
        echo ""
        echo -e "${BOLD}Permanent tunnel URLs:${RESET}"
        echo -e "  API:     ${CYAN}${API_URL:-N/A}${RESET}"
        echo -e "  Studio:  ${CYAN}${STUDIO_URL:-N/A}${RESET}"
        echo -e "  Coolify: ${CYAN}${COOLIFY_URL:-N/A}${RESET}"
    fi

    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════${RESET}"
    echo ""

    update_env_local "$WSL_IP" "$PUBLIC_IP" "$TAILSCALE_IP"
}

# =============================================================================
# SYNC COMMAND — Commit and push to both repos
# =============================================================================

cmd_sync() {
    local MSG="${1:-chore: update development environment}"
    banner "Colony Git Sync"

    info "Working directory: ${REPO_DIR}"

    # Stage everything
    git -C "$REPO_DIR" add -A
    if git -C "$REPO_DIR" diff --cached --quiet; then
        info "Nothing to commit — working tree clean."
    else
        info "Committing: ${MSG}"
        git -C "$REPO_DIR" commit -m "$MSG"
        success "Committed to local repository."
    fi

    # Push to main colony-app repo
    info "Pushing to colony-app (origin master)..."
    git -C "$REPO_DIR" push origin master
    success "Pushed to colony-app."

    # Push backend subtree to colony-backend repo
    info "Pushing backend subtree to colony-backend..."
    git -C "$REPO_DIR" subtree push --prefix=backend colony-backend master
    success "Pushed backend subtree to colony-backend."

    echo ""
    echo -e "${GREEN}${BOLD}Both repositories synced successfully.${RESET}"
    echo -e "  Main app:  ${CYAN}https://github.com/your-org/colony-app${RESET}"
    echo -e "  Backend:   ${CYAN}https://github.com/your-org/colony-backend${RESET}"
}

# =============================================================================
# MAIN DISPATCH
# =============================================================================

COMMAND="${1:-help}"
SUBARG="${2:-}"

case "$COMMAND" in
    start)
        cmd_start "$SUBARG"
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        cmd_stop
        sleep 1
        cmd_start "$SUBARG"
        ;;
    status|check|health)
        cmd_status
        ;;
    logs|log)
        cmd_logs
        ;;
    ip|network)
        cmd_ip
        ;;
    sync|push)
        cmd_sync "$SUBARG"
        ;;
    help|--help|-h|"")
        echo ""
        echo -e "${BOLD}${CYAN}Colony Session Manager${RESET}  — colony.sh"
        echo ""
        echo -e "${BOLD}Usage:${RESET}  bash scripts/colony.sh <command> [flags]"
        echo ""
        echo -e "${BOLD}SESSION COMMANDS${RESET}"
        echo -e "  ${GREEN}start${RESET}                       Start a dev session."
        echo -e "                              Pre-flight: ensures Docker is running, Supabase containers"
        echo -e "                              are up, detects WSL IP changes, updates .env.local."
        echo -e "                              Then shows an interactive menu to pick connection method."
        echo ""
        echo -e "  ${GREEN}start --cloudflare${RESET}  (-c)   Start Cloudflare tunnel directly (skip menu)."
        echo -e "                              Starts the cloudflared daemon, waits for connection,"
        echo -e "                              tests endpoint reachability, prints permanent URLs."
        echo ""
        echo -e "  ${GREEN}start --direct${RESET}      (-d)   Start with direct WSL/public IP (skip menu)."
        echo -e "                              Prints current WSL IP and all local service URLs."
        echo -e "                              Warning: WSL IP changes on every WSL restart."
        echo ""
        echo -e "  ${GREEN}start --tailscale${RESET}   (-t)   Start with Tailscale (skip menu)."
        echo -e "                              Verifies Tailscale is connected and prints stable"
        echo -e "                              100.x.x.x IP with all service URLs."
        echo ""
        echo -e "  ${GREEN}stop${RESET}                        Kill the running cloudflared tunnel daemon."
        echo ""
        echo -e "  ${GREEN}restart${RESET}                     Stop the tunnel, then start with same mode."
        echo ""
        echo -e "${BOLD}DIAGNOSTIC COMMANDS${RESET}"
        echo -e "  ${GREEN}status${RESET}                      Full visual health check. Checks:"
        echo -e "                              Docker daemon | Supabase containers | PostgreSQL extensions"
        echo -e "                              Local HTTP endpoints | Coolify | Cloudflare tunnel"
        echo -e "                              Cloudflare API tunnel status | Tailscale"
        echo -e "                              Prints ✓ / ~ / ✗ per item with pass/warn/fail counts."
        echo ""
        echo -e "  ${GREEN}logs${RESET}                        Tail the live Cloudflare tunnel log file."
        echo -e "                              Shows raw cloudflared output. Ctrl+C to exit."
        echo ""
        echo -e "  ${GREEN}ip${RESET}                          Print all network addresses:"
        echo -e "                              WSL IP (local, changes on restart)"
        echo -e "                              Public IP (your router's external address)"
        echo -e "                              Tailscale IP (stable, never changes)"
        echo -e "                              Also refreshes .env.local."
        echo ""
        echo -e "${BOLD}GIT COMMANDS${RESET}"
        echo -e "  ${GREEN}sync [\"message\"]${RESET}            Stage all changes, commit with message,"
        echo -e "                              push to colony-app (origin master),"
        echo -e "                              then push backend/ subtree to colony-backend."
        echo ""
        echo -e "${BOLD}FIRST-TIME SETUP (run once)${RESET}"
        echo -e "  bash scripts/colony-setup.sh              Install Docker + Coolify + Supabase"
        echo -e "  bash scripts/colony-setup.sh --cloudflare Wire Cloudflare tunnel + DNS"
        echo -e "  bash scripts/colony-setup.sh --tailscale  Install & connect Tailscale (optional)"
        echo -e "  bash scripts/colony-setup.sh --help       Full setup script help"
        echo ""
        echo -e "${BOLD}TYPICAL DAILY WORKFLOW${RESET}"
        echo -e "  bash scripts/colony.sh start              # select tunnel, starts everything"
        echo -e "  bash scripts/colony.sh status             # verify all green"
        echo -e "  bash scripts/colony.sh sync \"feat: ...\"   # commit and push"
        echo -e "  bash scripts/colony.sh stop               # end session"
        echo ""
        ;;
    *)
        error "Unknown command: ${COMMAND}"
        echo "Run: bash scripts/colony.sh help"
        exit 1
        ;;
esac
