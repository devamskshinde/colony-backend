#!/bin/bash
# =============================================================================
# tailscale-setup.sh — Install Tailscale in WSL and connect to your network.
# After running, you get a stable IP (100.x.x.x) that never changes — use
# this in your Flutter app for local device testing across any network.
#
# Usage:  bash scripts/tailscale-setup.sh
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
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/cloudflare.config.sh"

# ── Step 1: Install Tailscale ──────────────────────────────────────────────────
install_tailscale() {
    banner "Step 1: Installing Tailscale"
    if command -v tailscale &>/dev/null; then
        success "Tailscale already installed: $(tailscale version | head -1)"; return 0
    fi
    info "Installing Tailscale via official script..."
    curl -fsSL https://tailscale.com/install.sh | sh
    command -v tailscale &>/dev/null || fatal "Installation failed."
    success "Tailscale installed: $(tailscale version | head -1)"
}

# ── Step 2: Start tailscaled daemon ───────────────────────────────────────────
start_daemon() {
    banner "Step 2: Starting Tailscale Daemon"
    # In WSL, systemd may not be running — start daemon manually if needed
    if tailscale status &>/dev/null; then
        success "Tailscale daemon already running."
        return 0
    fi

    info "Starting tailscaled..."
    if command -v systemctl &>/dev/null && systemctl is-active --quiet tailscaled 2>/dev/null; then
        success "tailscaled running via systemd."
    else
        sudo tailscaled --state=/var/lib/tailscale/tailscaled.state \
            --socket=/run/tailscale/tailscaled.sock &>/tmp/tailscaled.log &
        sleep 3
        tailscale status &>/dev/null || fatal "tailscaled did not start. Check /tmp/tailscaled.log"
        success "tailscaled started."
    fi
}

# ── Step 3: Authenticate / Connect ────────────────────────────────────────────
connect_tailscale() {
    banner "Step 3: Connecting to Tailscale Network"

    # Check if already connected
    if tailscale status 2>/dev/null | grep -q "^[0-9]"; then
        TSIP="$(tailscale ip --4 2>/dev/null || echo 'unknown')"
        success "Already connected. Tailscale IP: ${TSIP}"
        return 0
    fi

    info "Opening browser for Tailscale login..."
    info "If running in a headless WSL, copy the URL that appears and open it in Windows."
    echo ""
    sudo tailscale up --accept-routes

    # Wait up to 60s for connection
    local ELAPSED=0
    while [[ $ELAPSED -lt 60 ]]; do
        if tailscale status 2>/dev/null | grep -q "^[0-9]"; then
            TSIP="$(tailscale ip --4 2>/dev/null || echo 'unknown')"
            success "Connected! Tailscale IP: ${TSIP}"
            return 0
        fi
        sleep 3; (( ELAPSED += 3 )) || true; echo -n "."
    done
    echo ""
    warn "Tailscale connection timeout. Check browser and try again."
}

# ── Step 4: Configure subnet routing ──────────────────────────────────────────
configure_routing() {
    banner "Step 4: Subnet Routing (optional)"
    # Advertise WSL subnet so Windows devices can reach WSL services directly
    WSL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '')"
    if [[ -n "$WSL_IP" ]]; then
        SUBNET="${WSL_IP%.*}.0/24"
        info "Advertising WSL subnet ${SUBNET} to Tailscale..."
        sudo tailscale up --advertise-routes="${SUBNET}" --accept-routes 2>/dev/null \
            || warn "Subnet routing may require approval in Tailscale admin console."
        info "Go to https://login.tailscale.com/admin/machines and enable route for this machine."
    fi
}

# ── Step 5: Update .env.local ──────────────────────────────────────────────────
update_env() {
    TSIP="$(tailscale ip --4 2>/dev/null || echo 'not-connected')"
    ENV_LOCAL="${BACKEND_DIR}/.env.local"

    if [[ -f "$ENV_LOCAL" ]]; then
        # Update existing
        if grep -q "TAILSCALE_IP=" "$ENV_LOCAL"; then
            sed -i "s|TAILSCALE_IP=.*|TAILSCALE_IP=${TSIP}|" "$ENV_LOCAL"
        else
            echo "TAILSCALE_IP=${TSIP}" >> "$ENV_LOCAL"
        fi
    else
        echo "TAILSCALE_IP=${TSIP}" > "$ENV_LOCAL"
    fi

    success ".env.local updated with TAILSCALE_IP=${TSIP}"
}

print_summary() {
    banner "Tailscale Setup Complete!"
    TSIP="$(tailscale ip --4 2>/dev/null || echo 'not-connected')"
    WSL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '?')"

    echo -e "${GREEN}${BOLD}Your stable Tailscale IP:  ${TSIP}${RESET}"
    echo ""
    echo -e "${BOLD}Use this in Flutter for local device testing:${RESET}"
    echo -e "  API:             http://${TSIP}:${LOCAL_PORT_API}"
    echo -e "  Supabase Studio: http://${TSIP}:${LOCAL_PORT_STUDIO}"
    echo -e "  Coolify:         http://${TSIP}:${LOCAL_PORT_COOLIFY}"
    echo ""
    echo -e "${BOLD}Why Tailscale instead of WSL IP?${RESET}"
    echo -e "  WSL IP (${WSL_IP}) changes every restart."
    echo -e "  Tailscale IP (${TSIP}) NEVER changes."
    echo -e "  Both your dev machine and phone just need Tailscale installed."
    echo ""
    echo -e "${BOLD}Install Tailscale on your phone/device:${RESET}"
    echo -e "  Android: Play Store → Tailscale"
    echo -e "  iOS:     App Store → Tailscale"
    echo -e "  Log in with the same account and all devices see each other."
}

main() {
    banner "Colony — Tailscale Setup"
    install_tailscale
    start_daemon
    connect_tailscale
    configure_routing
    update_env
    print_summary
}
main "$@"
