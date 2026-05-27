#!/bin/bash
# =============================================================================
# tunnel-status.sh — Visual health check for all Colony endpoints.
# Makes real HTTP requests and prints green ✓ / red ✗ per service.
#
# Usage:  bash scripts/tunnel-status.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/cloudflare.config.sh"

tunnel_is_running() {
    [[ -f "$CF_TUNNEL_PID_FILE" ]] && kill -0 "$(cat "$CF_TUNNEL_PID_FILE")" 2>/dev/null && return 0
    pgrep -f "cloudflared.*${CF_TUNNEL_NAME}" &>/dev/null && return 0; return 1
}

check_url() {
    local URL="$1" LABEL="$2"
    local RESULT; RESULT="$(curl -sSo /dev/null -w '%{http_code} %{time_total}' --max-time 10 "$URL" 2>/dev/null || echo "000 0")"
    local CODE; CODE="$(echo "$RESULT" | awk '{print $1}')"
    local MS;   MS="$(echo "$RESULT"   | awk '{printf "%.0f", $2*1000}')"
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

cf_tunnel_health() {
    [[ -z "$CF_API_TOKEN" ]] && return
    STATUS="$(curl -sSf "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=${CF_TUNNEL_NAME}&is_deleted=false" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" 2>/dev/null \
        | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0].get('status','unknown') if r else 'not-found')" 2>/dev/null || echo "unknown")"
    case "$STATUS" in
        healthy)   echo -e "  ${GREEN}● healthy${RESET}" ;;
        inactive)  echo -e "  ${YELLOW}● inactive (no active connections)${RESET}" ;;
        degraded)  echo -e "  ${YELLOW}● degraded${RESET}" ;;
        not-found) echo -e "  ${YELLOW}● not found — run cloudflare-setup.sh${RESET}" ;;
        *)         echo -e "  ${CYAN}● ${STATUS}${RESET}" ;;
    esac
}

main() {
    echo ""
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${CYAN}  Colony Tunnel Status — ${CF_TUNNEL_NAME}${RESET}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${RESET}"
    echo ""

    echo -e "${BOLD}Local daemon:${RESET}"
    if tunnel_is_running; then
        PID="$(cat "$CF_TUNNEL_PID_FILE" 2>/dev/null || pgrep -f "cloudflared.*${CF_TUNNEL_NAME}" | head -1 || echo '?')"
        echo -e "  ${GREEN}● Running${RESET} (PID: ${PID})"
        [[ -f "$CF_TUNNEL_LOG_FILE" ]] && LAST="$(tail -1 "$CF_TUNNEL_LOG_FILE" 2>/dev/null | grep -v '^$' || true)" && [[ -n "$LAST" ]] && echo -e "  ${CYAN}Last log:${RESET} ${LAST}"
    else
        echo -e "  ${RED}● Stopped${RESET}  →  bash scripts/tunnel.sh start"
    fi

    echo ""
    echo -e "${BOLD}Cloudflare health:${RESET}"
    cf_tunnel_health

    BACKEND_DIR="$(dirname "$SCRIPT_DIR")"
    echo ""
    echo -e "${BOLD}.env.tunnel:${RESET}"
    [[ -f "${BACKEND_DIR}/.env.tunnel" ]] \
        && echo -e "  ${GREEN}✓${RESET}  exists" \
        || echo -e "  ${RED}✗${RESET}  missing — run cloudflare-setup.sh"

    echo ""
    echo -e "${BOLD}Endpoints:${RESET}"
    ALL_OK=true
    check_url "$CF_API_URL"     "API    " || ALL_OK=false; echo ""
    check_url "$CF_ADMIN_URL"   "Admin  " || ALL_OK=false; echo ""
    check_url "$CF_STUDIO_URL"  "Studio " || ALL_OK=false; echo ""
    check_url "$CF_COOLIFY_URL" "Coolify" || ALL_OK=false; echo ""

    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${RESET}"
    if $ALL_OK; then
        echo -e "${GREEN}${BOLD}All systems operational.${RESET}"
    else
        echo -e "${YELLOW}${BOLD}Some endpoints unreachable.${RESET}"
        echo -e "  • Start local services (API, Studio, Coolify)"
        echo -e "  • Start tunnel: bash scripts/tunnel.sh start"
        echo -e "  • DNS may still be propagating (allow 60s after setup)"
    fi
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════════${RESET}"
    echo ""
    $ALL_OK && exit 0 || exit 1
}
main "$@"
