#!/bin/bash
# =============================================================================
# verify.sh — Colony Service Health Check
# Checks every service and prints a clear pass/fail for each.
# Run after setup or whenever something seems broken.
#
# Usage:  bash scripts/verify.sh
# Exit code: 0 = all passing, 1 = some failures
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"
SUPABASE_DIR="${BACKEND_DIR}/docker/supabase"
source "${SCRIPT_DIR}/cloudflare.config.sh"

PASS=0; FAIL=0; WARN=0

check_pass() { echo -e "  ${GREEN}✓${RESET}  $*"; (( PASS++ )) || true; }
check_fail() { echo -e "  ${RED}✗${RESET}  $*"; (( FAIL++ )) || true; }
check_warn() { echo -e "  ${YELLOW}~${RESET}  $*"; (( WARN++ )) || true; }
section()    { echo -e "\n${BOLD}${CYAN}── $* ──────────────────────────────${RESET}"; }

WSL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '127.0.0.1')"

# ── Docker ─────────────────────────────────────────────────────────────────────
check_docker() {
    section "Docker"
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        check_pass "Docker Engine running ($(docker --version | head -1))"
    else
        check_fail "Docker is not running — run: sudo service docker start"
    fi

    if command -v docker-compose &>/dev/null || docker compose version &>/dev/null 2>/dev/null; then
        check_pass "docker compose available"
    else
        check_fail "docker compose not found"
    fi
}

# ── Supabase containers ────────────────────────────────────────────────────────
check_supabase_containers() {
    section "Supabase Containers"
    declare -A EXPECTED=(
        ["colony-db"]="PostgreSQL"
        ["colony-kong"]="Kong (API Gateway)"
        ["colony-auth"]="Auth (GoTrue)"
        ["colony-rest"]="PostgREST (REST API)"
        ["colony-realtime"]="Realtime"
        ["colony-storage"]="Storage"
        ["colony-studio"]="Supabase Studio"
        ["colony-meta"]="Supabase Meta"
        ["colony-analytics"]="Analytics (Logflare)"
        ["colony-imgproxy"]="Image Proxy"
    )

    for CONTAINER in "${!EXPECTED[@]}"; do
        LABEL="${EXPECTED[$CONTAINER]}"
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER}$"; then
            check_fail "${LABEL} — container not running"
            continue
        fi
        HEALTH="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' \
            "$CONTAINER" 2>/dev/null || echo 'inspect-failed')"
        case "$HEALTH" in
            healthy|no-healthcheck) check_pass "${LABEL}" ;;
            starting) check_warn "${LABEL} — still starting up" ;;
            unhealthy) check_fail "${LABEL} — UNHEALTHY (docker logs ${CONTAINER})" ;;
            *) check_warn "${LABEL} — ${HEALTH}" ;;
        esac
    done
}

# ── PostgreSQL connectivity ────────────────────────────────────────────────────
check_postgres() {
    section "PostgreSQL"

    if docker exec colony-db pg_isready -U postgres &>/dev/null; then
        check_pass "PostgreSQL accepting connections"
    else
        check_fail "PostgreSQL NOT accepting connections"
        return
    fi

    # Check PostGIS
    POSTGIS="$(docker exec colony-db psql -U postgres -tAc \
        "SELECT COUNT(*) FROM pg_extension WHERE extname='postgis';" 2>/dev/null || echo '0')"
    [[ "$POSTGIS" == "1" ]] && check_pass "PostGIS extension installed" || check_fail "PostGIS NOT installed"

    # Check uuid-ossp
    UUID_EXT="$(docker exec colony-db psql -U postgres -tAc \
        "SELECT COUNT(*) FROM pg_extension WHERE extname='uuid-ossp';" 2>/dev/null || echo '0')"
    [[ "$UUID_EXT" == "1" ]] && check_pass "uuid-ossp extension installed" || check_fail "uuid-ossp NOT installed"

    # Check pg_trgm
    TRGM="$(docker exec colony-db psql -U postgres -tAc \
        "SELECT COUNT(*) FROM pg_extension WHERE extname='pg_trgm';" 2>/dev/null || echo '0')"
    [[ "$TRGM" == "1" ]] && check_pass "pg_trgm extension installed" || check_fail "pg_trgm NOT installed"

    # Check pgcrypto
    CRYPTO="$(docker exec colony-db psql -U postgres -tAc \
        "SELECT COUNT(*) FROM pg_extension WHERE extname='pgcrypto';" 2>/dev/null || echo '0')"
    [[ "$CRYPTO" == "1" ]] && check_pass "pgcrypto extension installed" || check_fail "pgcrypto NOT installed"
}

# ── HTTP services ──────────────────────────────────────────────────────────────
check_http() {
    local URL="$1" LABEL="$2" EXPECT_CODE="${3:-200}"
    local CODE; CODE="$(curl -sSo /dev/null -w '%{http_code}' --max-time 8 "$URL" 2>/dev/null || echo '000')"
    case "$CODE" in
        2*|3*|401|403) check_pass "${LABEL} (HTTP ${CODE})" ;;
        000)           check_fail "${LABEL} — connection refused" ;;
        *)             check_warn "${LABEL} — HTTP ${CODE}" ;;
    esac
}

check_local_services() {
    section "Local HTTP Services"
    check_http "http://${WSL_IP}:${LOCAL_PORT_STUDIO}"   "Supabase Studio"
    check_http "http://${WSL_IP}:${LOCAL_PORT_SUPABASE}" "Supabase Kong API"
    check_http "http://${WSL_IP}:${LOCAL_PORT_COOLIFY}"  "Coolify Dashboard"
}

# ── Realtime ───────────────────────────────────────────────────────────────────
check_realtime() {
    section "Supabase Realtime"
    if docker exec colony-realtime wget -qO- http://localhost:4000/health 2>/dev/null | grep -q "ok\|healthy\|alive"; then
        check_pass "Realtime health endpoint OK"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^colony-realtime$"; then
        check_warn "Realtime container running (health endpoint not responding)"
    else
        check_fail "Realtime container not found"
    fi
}

# ── Storage ────────────────────────────────────────────────────────────────────
check_storage() {
    section "Supabase Storage"
    if docker exec colony-storage wget -qO- http://localhost:5000/status 2>/dev/null | grep -q "ok\|healthy\|alive"; then
        check_pass "Storage health endpoint OK"
    elif docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^colony-storage$"; then
        check_warn "Storage container running (health endpoint not responding)"
    else
        check_fail "Storage container not found"
    fi
}

# ── Coolify ────────────────────────────────────────────────────────────────────
check_coolify() {
    section "Coolify"
    if docker ps 2>/dev/null | grep -q "coolify"; then
        check_pass "Coolify container(s) running"
    else
        check_fail "Coolify not running — run: bash scripts/setup.sh"
    fi
    check_http "http://${WSL_IP}:${LOCAL_PORT_COOLIFY}" "Coolify web UI"
}

# ── Cloudflare Tunnel ──────────────────────────────────────────────────────────
check_tunnel() {
    section "Cloudflare Tunnel"

    # Check daemon
    if [[ -f "$CF_TUNNEL_PID_FILE" ]] && kill -0 "$(cat "$CF_TUNNEL_PID_FILE")" 2>/dev/null; then
        check_pass "cloudflared daemon running (PID $(cat "$CF_TUNNEL_PID_FILE"))"
    elif pgrep -f "cloudflared.*${CF_TUNNEL_NAME}" &>/dev/null; then
        check_pass "cloudflared daemon running (via pgrep)"
    else
        check_warn "Tunnel daemon not running — start with: bash scripts/tunnel.sh start"
    fi

    # Check .env.tunnel
    [[ -f "${BACKEND_DIR}/.env.tunnel" ]] \
        && check_pass ".env.tunnel file exists" \
        || check_fail ".env.tunnel missing — run: bash scripts/cloudflare-setup.sh"

    # Check public endpoints
    check_http "$CF_API_URL"     "API endpoint (${CF_API_URL})"
    check_http "$CF_STUDIO_URL"  "Studio endpoint (${CF_STUDIO_URL})"
    check_http "$CF_COOLIFY_URL" "Coolify endpoint (${CF_COOLIFY_URL})"
}

# ── Tailscale ──────────────────────────────────────────────────────────────────
check_tailscale() {
    section "Tailscale (optional)"
    if ! command -v tailscale &>/dev/null; then
        check_warn "Tailscale not installed (optional — for device testing)"
        return
    fi
    TSIP="$(tailscale ip --4 2>/dev/null || echo '')"
    if [[ -n "$TSIP" ]]; then
        check_pass "Connected — Tailscale IP: ${TSIP}"
    else
        check_warn "Tailscale installed but not connected — run: bash scripts/tailscale-setup.sh"
    fi
}

# ── Summary ────────────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${RESET}"
    echo -e "${BOLD}Colony Verify Summary${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${RESET}"
    echo -e "  ${GREEN}✓ Passed: ${PASS}${RESET}"
    echo -e "  ${YELLOW}~ Warnings: ${WARN}${RESET}"
    echo -e "  ${RED}✗ Failed: ${FAIL}${RESET}"
    echo ""

    if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
        echo -e "${GREEN}${BOLD}All checks passed — environment fully operational!${RESET}"
    elif [[ $FAIL -eq 0 ]]; then
        echo -e "${YELLOW}${BOLD}Minor warnings — environment usable, check warnings above.${RESET}"
    else
        echo -e "${RED}${BOLD}${FAIL} check(s) failed — investigate above.${RESET}"
        echo ""
        echo -e "${BOLD}Common fixes:${RESET}"
        echo -e "  Docker not running:   sudo service docker start"
        echo -e "  Supabase not running: docker compose -f ${SUPABASE_DIR}/docker-compose.yml up -d"
        echo -e "  Coolify not running:  bash scripts/setup.sh"
        echo -e "  Tunnel not running:   bash scripts/tunnel.sh start"
        echo -e "  Extensions missing:   docker restart colony-db (runs init SQL)"
    fi
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${RESET}"
    echo ""

    [[ $FAIL -eq 0 ]] && exit 0 || exit 1
}

main() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  Colony — Environment Health Check${RESET}"
    echo -e "${BOLD}${CYAN}  $(date)${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${RESET}"

    check_docker
    check_supabase_containers
    check_postgres
    check_local_services
    check_realtime
    check_storage
    check_coolify
    check_tunnel
    check_tailscale
    print_summary
}
main "$@"
