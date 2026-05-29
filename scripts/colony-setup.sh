#!/bin/bash
# =============================================================================
# colony-setup.sh — Colony Intelligent Installer
#
# ONE script replaces: setup.sh + cloudflare-setup.sh + tailscale-setup.sh
#
# Usage:
#   bash scripts/colony-setup.sh              # Full fresh setup (auto-detects what's already done)
#   bash scripts/colony-setup.sh --cloudflare # One-time Cloudflare tunnel wiring
#   bash scripts/colony-setup.sh --tailscale  # Install & connect Tailscale
#   bash scripts/colony-setup.sh --check      # Only check prerequisites, no installs
#
# Idempotent: safe to re-run at any time. Skips steps already completed.
# =============================================================================

set -euo pipefail

# ── Colours & logging helpers ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
fatal()   { error "$*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}\n"; }
banner()  {
    echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║  $*${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}\n"
}

# ── Paths ─────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"
SUPABASE_DIR="${BACKEND_DIR}/docker/supabase"
CONFIG_FILE="${SCRIPT_DIR}/cloudflare.config.sh"

[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" || {
    warn "cloudflare.config.sh not found — Cloudflare features will be unavailable."
}

SETUP_LOG="/tmp/colony-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$SETUP_LOG") 2>&1
info "Logging all output to ${SETUP_LOG}"

# ── Retry helper ──────────────────────────────────────────────────────────────
retry() {
    local N=1 MAX="$1" DELAY="$2"; shift 2
    while true; do
        "$@" && return 0
        if [[ $N -lt $MAX ]]; then
            warn "Attempt $N/$MAX failed — retrying in ${DELAY}s..."
            sleep "$DELAY"; (( N++ )) || true
        else
            error "Command failed after $MAX attempts: $*"
            return 1
        fi
    done
}

# =============================================================================
# SECTION A: FULL SETUP — Prerequisites, Docker, Coolify, Supabase
# =============================================================================

# ── A1: Prerequisites ─────────────────────────────────────────────────────────
check_prerequisites() {
    step "A1: System Prerequisites"

    if grep -qi microsoft /proc/version 2>/dev/null; then
        success "WSL detected: $(grep -i microsoft /proc/version | head -1 | cut -c1-80)"
    else
        warn "Not WSL — this script is designed for WSL2. Proceeding anyway..."
    fi

    local MISSING=()
    for cmd in curl git python3 jq; do
        if command -v "$cmd" &>/dev/null; then
            success "$cmd found: $(command -v "$cmd")"
        else
            MISSING+=("$cmd")
        fi
    done

    if [[ ${#MISSING[@]} -gt 0 ]]; then
        info "Installing missing tools: ${MISSING[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${MISSING[@]}"
        success "Prerequisites installed."
    else
        success "All prerequisites present."
    fi
}

# ── A2: Docker Engine ─────────────────────────────────────────────────────────
install_docker() {
    step "A2: Docker Engine"

    # Already running
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        success "Docker already running: $(docker --version)"
        return 0
    fi

    # Installed but not running — try to start it
    if command -v docker &>/dev/null; then
        info "Docker installed but not running. Starting..."
        sudo service docker start 2>/dev/null || sudo dockerd &>/tmp/dockerd.log &
        sleep 5
        docker info &>/dev/null && { success "Docker started."; return 0; } || true
    fi

    info "Installing Docker Engine (official apt method)..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add current user to docker group
    sudo usermod -aG docker "$USER"
    info "Added ${USER} to docker group. You may need: newgrp docker"

    # Start Docker
    sudo service docker start || sudo dockerd &>/tmp/dockerd.log &
    sleep 5

    # Auto-start on WSL session
    if ! grep -q "service docker start" "${HOME}/.bashrc" 2>/dev/null; then
        echo '' >> "${HOME}/.bashrc"
        echo '# Colony: auto-start Docker on WSL session' >> "${HOME}/.bashrc"
        echo 'sudo service docker start 2>/dev/null || true' >> "${HOME}/.bashrc"
        info "Added Docker auto-start to ~/.bashrc"
    fi

    docker info &>/dev/null || fatal "Docker failed to start. Check /tmp/dockerd.log"
    success "Docker installed: $(docker --version)"

    # Standalone compose fallback
    if ! command -v docker-compose &>/dev/null; then
        info "Installing docker-compose standalone..."
        local VER; VER="$(curl -sSf https://api.github.com/repos/docker/compose/releases/latest \
            | grep '"tag_name"' | cut -d'"' -f4)"
        sudo curl -fsSL \
            "https://github.com/docker/compose/releases/download/${VER}/docker-compose-$(uname -s)-$(uname -m)" \
            -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        success "docker-compose installed: $(docker-compose --version)"
    fi
}

# ── A3: Coolify ────────────────────────────────────────────────────────────────
install_coolify() {
    step "A3: Coolify"

    if docker ps 2>/dev/null | grep -q "coolify"; then
        local WSL_IP; WSL_IP="$(hostname -I | awk '{print $1}')"
        success "Coolify already running at http://${WSL_IP}:8000"
        return 0
    fi

    info "Installing Coolify (pulls ~500 MB of images — this may take several minutes)..."
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash

    local WSL_IP; WSL_IP="$(hostname -I | awk '{print $1}')"
    info "Waiting for Coolify to respond at http://${WSL_IP}:8000..."
    local ELAPSED=0
    while [[ $ELAPSED -lt 120 ]]; do
        if curl -sSf --max-time 5 "http://${WSL_IP}:8000" &>/dev/null; then
            success "Coolify is up: http://${WSL_IP}:8000"
            return 0
        fi
        sleep 5; (( ELAPSED += 5 )) || true; echo -n "."
    done
    echo ""
    warn "Coolify did not respond in 120s."
    warn "Check: docker ps | grep coolify"
}

# ── A4: Supabase via Docker Compose ───────────────────────────────────────────
deploy_supabase() {
    step "A4: Supabase Self-Hosted"

    [[ -f "${SUPABASE_DIR}/docker-compose.yml" ]] \
        || fatal "Supabase docker-compose.yml not found at ${SUPABASE_DIR}"

    local ENV_FILE="${SUPABASE_DIR}/.env.supabase"
    [[ -f "$ENV_FILE" ]] || fatal ".env.supabase not found at ${ENV_FILE}"

    if docker compose -f "${SUPABASE_DIR}/docker-compose.yml" \
        --env-file "$ENV_FILE" ps 2>/dev/null | grep -q "running"; then
        success "Supabase containers already running."
        return 0
    fi

    info "Pulling Supabase Docker images (first run ~2 GB, subsequent runs use cache)..."
    docker compose -f "${SUPABASE_DIR}/docker-compose.yml" --env-file "$ENV_FILE" pull

    info "Starting Supabase services..."
    docker compose -f "${SUPABASE_DIR}/docker-compose.yml" --env-file "$ENV_FILE" up -d

    success "Supabase containers started."
}

# ── A5: Wait for healthy state ────────────────────────────────────────────────
wait_for_services() {
    step "A5: Waiting for Services to Become Healthy"

    local MAX_WAIT=300 ELAPSED=0
    declare -A SERVICES=(
        ["colony-db"]="PostgreSQL"
        ["colony-studio"]="Supabase Studio"
        ["colony-kong"]="Supabase API Gateway"
        ["colony-auth"]="Auth Service"
        ["colony-rest"]="PostgREST"
        ["colony-realtime"]="Realtime"
        ["colony-storage"]="Storage"
    )

    info "Waiting up to ${MAX_WAIT}s for all containers to be healthy..."
    while [[ $ELAPSED -lt $MAX_WAIT ]]; do
        local ALL_HEALTHY=true
        for CONTAINER in "${!SERVICES[@]}"; do
            local STATUS; STATUS="$(docker inspect --format='{{.State.Health.Status}}' \
                "$CONTAINER" 2>/dev/null || echo "missing")"
            [[ "$STATUS" != "healthy" ]] && ALL_HEALTHY=false
        done
        $ALL_HEALTHY && { success "All services healthy!"; break; }
        sleep 5; (( ELAPSED += 5 )) || true; echo -n "."
    done
    echo ""

    for CONTAINER in "${!SERVICES[@]}"; do
        local STATUS; STATUS="$(docker inspect --format='{{.State.Health.Status}}' \
            "$CONTAINER" 2>/dev/null || echo "missing")"
        local LABEL="${SERVICES[$CONTAINER]}"
        case "$STATUS" in
            healthy)   echo -e "  ${GREEN}✓${RESET}  ${LABEL} (${CONTAINER})" ;;
            starting)  echo -e "  ${YELLOW}~${RESET}  ${LABEL} — still starting" ;;
            unhealthy) echo -e "  ${RED}✗${RESET}  ${LABEL} — UNHEALTHY" ;;
            missing)   echo -e "  ${RED}✗${RESET}  ${LABEL} — container not found" ;;
            *)         echo -e "  ${YELLOW}?${RESET}  ${LABEL} — ${STATUS}" ;;
        esac
    done
}

# ── A6: Database setup ────────────────────────────────────────────────────────
setup_database() {
    step "A6: Database Configuration"

    local RETRIES=0
    while ! docker exec colony-db pg_isready -U postgres &>/dev/null; do
        [[ $RETRIES -lt 30 ]] || fatal "PostgreSQL not ready after 150s."
        sleep 5; (( RETRIES++ )) || true; echo -n "."
    done
    echo ""
    success "PostgreSQL accepting connections."

    info "Verifying PostgreSQL extensions..."
    for EXT in uuid-ossp postgis pg_trgm pgcrypto; do
        local COUNT; COUNT="$(docker exec colony-db psql -U postgres -tAc \
            "SELECT COUNT(*) FROM pg_extension WHERE extname='${EXT}';" 2>/dev/null || echo '0')"
        [[ "$COUNT" == "1" ]] \
            && success "Extension ${EXT}: installed" \
            || warn "Extension ${EXT}: not installed (applied via init SQL on first boot)"
    done

    # Idempotent schema marker
    docker exec colony-db psql -U postgres -c \
        "CREATE TABLE IF NOT EXISTS public._colony_meta (
            key TEXT PRIMARY KEY, value TEXT, created_at TIMESTAMPTZ DEFAULT NOW()
        );" &>/dev/null || true
    docker exec colony-db psql -U postgres -c \
        "INSERT INTO public._colony_meta (key, value) VALUES ('setup_version', '1.0')
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, created_at = NOW();" \
        &>/dev/null || true

    success "Database configured."
}

# ── A7: Summary after full setup ──────────────────────────────────────────────
print_full_summary() {
    local WSL_IP; WSL_IP="$(hostname -I | awk '{print $1}')"
    banner "Colony Dev Environment Ready!"

    echo -e "${BOLD}Local URLs (WSL network):${RESET}"
    echo -e "  Coolify:         ${CYAN}http://${WSL_IP}:${LOCAL_PORT_COOLIFY:-8000}${RESET}"
    echo -e "  Supabase Studio: ${CYAN}http://${WSL_IP}:${LOCAL_PORT_STUDIO:-3002}${RESET}"
    echo -e "  Supabase API:    ${CYAN}http://${WSL_IP}:${LOCAL_PORT_SUPABASE:-8001}${RESET}"
    echo ""

    if [[ -f "${BACKEND_DIR}/.env.tunnel" ]]; then
        # shellcheck source=/dev/null
        source "${BACKEND_DIR}/.env.tunnel"
        echo -e "${BOLD}Permanent Public URLs:${RESET}"
        echo -e "  API:     ${CYAN}${API_URL:-N/A}${RESET}"
        echo -e "  Admin:   ${CYAN}${ADMIN_URL:-N/A}${RESET}"
        echo -e "  Studio:  ${CYAN}${STUDIO_URL:-N/A}${RESET}"
        echo -e "  Coolify: ${CYAN}${COOLIFY_URL:-N/A}${RESET}"
        echo ""
    else
        warn ".env.tunnel not found — run: bash scripts/colony-setup.sh --cloudflare"
    fi

    echo -e "${BOLD}Next steps:${RESET}"
    echo -e "  1. Coolify setup:     Open ${CYAN}http://${WSL_IP}:${LOCAL_PORT_COOLIFY:-8000}${RESET} → create admin account"
    echo -e "  2. Start tunnel:      ${YELLOW}bash scripts/colony.sh start${RESET}"
    echo -e "  3. Health check:      ${YELLOW}bash scripts/colony.sh status${RESET}"
    echo -e "  4. Cloudflare wiring: ${YELLOW}bash scripts/colony-setup.sh --cloudflare${RESET}  (run once)"
    echo -e "  5. Tailscale (opt):   ${YELLOW}bash scripts/colony-setup.sh --tailscale${RESET}"
    echo ""
    echo -e "${GREEN}${BOLD}Setup complete!${RESET}  Full log saved to: ${SETUP_LOG}"
}

# =============================================================================
# SECTION B: CLOUDFLARE TUNNEL WIRING (--cloudflare)
# =============================================================================

# ── B1: Install cloudflared ───────────────────────────────────────────────────
install_cloudflared() {
    step "B1: Install cloudflared"

    if command -v cloudflared &>/dev/null; then
        success "cloudflared already installed: $(cloudflared --version)"
        return 0
    fi

    local DISTRO="unknown"
    [[ -f /etc/os-release ]] && source /etc/os-release && DISTRO="${ID:-unknown}"

    case "$DISTRO" in
        ubuntu|debian|linuxmint|pop|kali)
            sudo apt-get update -qq
            sudo apt-get install -y -qq curl gnupg lsb-release
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
                | sudo gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] \
https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
                | sudo tee /etc/apt/sources.list.d/cloudflared.list > /dev/null
            sudo apt-get update -qq && sudo apt-get install -y cloudflared ;;
        fedora|centos|rhel|rocky|almalinux)
            sudo rpm --import https://pkg.cloudflare.com/cloudflare-main.gpg
            curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo \
                | sudo tee /etc/yum.repos.d/cloudflared.repo > /dev/null
            sudo dnf install -y cloudflared ;;
        *)
            warn "Unknown distro — falling back to binary download."
            local ARCH; ARCH="$(uname -m)"
            local URL
            case "$ARCH" in
                x86_64)  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
                aarch64) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
                *)       fatal "Unsupported architecture: $ARCH" ;;
            esac
            curl -fsSL "$URL" -o /tmp/cloudflared
            sudo install -m755 /tmp/cloudflared /usr/local/bin/cloudflared
            rm -f /tmp/cloudflared ;;
    esac

    command -v cloudflared &>/dev/null || fatal "cloudflared installation failed."
    success "Installed: $(cloudflared --version)"
}

# ── B2: Authenticate with Cloudflare ─────────────────────────────────────────
authenticate_cloudflare() {
    step "B2: Cloudflare Authentication"

    [[ -n "${CF_CREDENTIALS_DIR:-}" ]] || fatal "CF_CREDENTIALS_DIR not set. cloudflare.config.sh missing?"

    if [[ -f "${CF_CREDENTIALS_DIR}/cert.pem" ]]; then
        success "Already authenticated (cert.pem exists)."
        return 0
    fi

    info "Opening browser for Cloudflare login — authorize for domain: ${CF_DOMAIN}"
    info "If using headless WSL, copy the URL shown and open it in Windows browser."
    cloudflared tunnel login
    [[ -f "${CF_CREDENTIALS_DIR}/cert.pem" ]] || fatal "Auth failed — cert.pem was not created."
    success "Authenticated successfully."
}

# ── B3: Create named tunnel ───────────────────────────────────────────────────
create_tunnel() {
    step "B3: Create Named Tunnel"

    if cloudflared tunnel list 2>/dev/null | grep -q "\b${CF_TUNNEL_NAME}\b"; then
        success "Tunnel '${CF_TUNNEL_NAME}' already exists — skipping creation."
        return 0
    fi

    cloudflared tunnel create "${CF_TUNNEL_NAME}"
    [[ -f "$CF_TUNNEL_CREDENTIALS_FILE" ]] || fatal "Credentials file not created after tunnel create."
    success "Tunnel '${CF_TUNNEL_NAME}' created."
}

# ── B4: Write cloudflared config.yml ─────────────────────────────────────────
write_tunnel_config() {
    step "B4: Write Tunnel config.yml"

    local TUNNEL_ID
    TUNNEL_ID="$(python3 -c "
import json
with open('${CF_TUNNEL_CREDENTIALS_FILE}') as f:
    d = json.load(f)
print(d.get('TunnelID', d.get('tunnelID', d.get('tunnel_id', ''))))
" 2>/dev/null || true)"

    if [[ -z "$TUNNEL_ID" ]]; then
        TUNNEL_ID="$(cloudflared tunnel list --output json 2>/dev/null \
            | python3 -c "
import json,sys
tunnels = json.load(sys.stdin)
matches = [t['id'] for t in tunnels if t.get('name') == '${CF_TUNNEL_NAME}']
print(matches[0] if matches else '')
" 2>/dev/null || true)"
    fi

    [[ -n "$TUNNEL_ID" ]] || fatal "Cannot determine tunnel ID — check cloudflared tunnel list."
    info "Tunnel ID: ${TUNNEL_ID}"

    mkdir -p "$CF_CREDENTIALS_DIR"
    cat > "$CF_TUNNEL_CONFIG_FILE" <<CFEOF
# cloudflared config — auto-generated by colony-setup.sh --cloudflare
tunnel: ${TUNNEL_ID}
credentials-file: ${CF_TUNNEL_CREDENTIALS_FILE}

ingress:
  - hostname: ${CF_SUBDOMAIN_API}.${CF_DOMAIN}
    service: http://localhost:${LOCAL_PORT_API}
  - hostname: ${CF_SUBDOMAIN_ADMIN}.${CF_DOMAIN}
    service: http://localhost:${LOCAL_PORT_ADMIN}
  - hostname: ${CF_SUBDOMAIN_STUDIO}.${CF_DOMAIN}
    service: http://localhost:${LOCAL_PORT_STUDIO}
  - hostname: ${CF_SUBDOMAIN_COOLIFY}.${CF_DOMAIN}
    service: http://localhost:${LOCAL_PORT_COOLIFY}
  - service: http_status:404
CFEOF
    success "Config written to ${CF_TUNNEL_CONFIG_FILE}"
}

# ── B5: Create DNS CNAME records via Cloudflare API ───────────────────────────
create_dns_records() {
    step "B5: Create DNS CNAME Records"

    local ZONE_RESP ZONE_ID
    ZONE_RESP="$(curl -sSf "https://api.cloudflare.com/client/v4/zones?name=${CF_DOMAIN}&status=active" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")"
    ZONE_ID="$(echo "$ZONE_RESP" | python3 -c \
        "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" \
        2>/dev/null || true)"
    [[ -n "$ZONE_ID" ]] || fatal "Cannot resolve Zone ID for ${CF_DOMAIN}. Check API token Zone:Read permission."
    info "Zone ID: ${ZONE_ID}"

    local TUNNEL_ID
    TUNNEL_ID="$(python3 -c "
import json
with open('${CF_TUNNEL_CREDENTIALS_FILE}') as f:
    d = json.load(f)
print(d.get('TunnelID', d.get('tunnelID', '')))
" 2>/dev/null || true)"
    local CNAME_TARGET="${TUNNEL_ID}.cfargotunnel.com"
    info "CNAME target: ${CNAME_TARGET}"

    local SUBDOMAINS=("$CF_SUBDOMAIN_API" "$CF_SUBDOMAIN_ADMIN" "$CF_SUBDOMAIN_STUDIO" "$CF_SUBDOMAIN_COOLIFY")
    for SUB in "${SUBDOMAINS[@]}"; do
        local FULL="${SUB}.${CF_DOMAIN}"
        local EXISTING_ID
        EXISTING_ID="$(curl -sSf \
            "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=CNAME&name=${FULL}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
            | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" \
            2>/dev/null || true)"

        local PAYLOAD="{\"type\":\"CNAME\",\"name\":\"${FULL}\",\"content\":\"${CNAME_TARGET}\",\"proxied\":true,\"comment\":\"colony-dev auto-managed\"}"

        if [[ -n "$EXISTING_ID" ]]; then
            local RESP; RESP="$(curl -sSf -X PUT \
                "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${EXISTING_ID}" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
                --data "$PAYLOAD")"
            local OK; OK="$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success',False))" 2>/dev/null)"
            [[ "$OK" == "True" ]] && success "Updated CNAME: ${FULL}" || warn "Update failed for ${FULL}: ${RESP}"
        else
            local RESP; RESP="$(curl -sSf -X POST \
                "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
                --data "$PAYLOAD")"
            local OK; OK="$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success',False))" 2>/dev/null)"
            [[ "$OK" == "True" ]] && success "Created CNAME: ${FULL}" || error "Failed: ${FULL} — ${RESP}"
        fi
    done
}

# ── B6: Write .env.tunnel ─────────────────────────────────────────────────────
write_env_tunnel() {
    step "B6: Write .env.tunnel"

    cat > "${BACKEND_DIR}/.env.tunnel" <<ENVEOF
# .env.tunnel — auto-generated by colony-setup.sh --cloudflare
# These URLs are PERMANENT — they survive all restarts, NAT changes, and IP changes.
# Source this file:     source backend/.env.tunnel
# Flutter build:        --dart-define-from-file=backend/.env.tunnel

TUNNEL_NAME=${CF_TUNNEL_NAME}
DOMAIN=${CF_DOMAIN}

API_URL=https://${CF_SUBDOMAIN_API}.${CF_DOMAIN}
ADMIN_URL=https://${CF_SUBDOMAIN_ADMIN}.${CF_DOMAIN}
STUDIO_URL=https://${CF_SUBDOMAIN_STUDIO}.${CF_DOMAIN}
COOLIFY_URL=https://${CF_SUBDOMAIN_COOLIFY}.${CF_DOMAIN}

NEXT_PUBLIC_API_URL=https://${CF_SUBDOMAIN_API}.${CF_DOMAIN}
SUPABASE_STUDIO_URL=https://${CF_SUBDOMAIN_STUDIO}.${CF_DOMAIN}
ENVEOF
    success ".env.tunnel written to ${BACKEND_DIR}/.env.tunnel"
}

print_cloudflare_summary() {
    banner "Cloudflare Tunnel Wired!"
    echo -e "${GREEN}${BOLD}Permanent URLs (never change across restarts):${RESET}"
    echo -e "  🌐  API:     ${CYAN}https://${CF_SUBDOMAIN_API}.${CF_DOMAIN}${RESET}"
    echo -e "  🌐  Admin:   ${CYAN}https://${CF_SUBDOMAIN_ADMIN}.${CF_DOMAIN}${RESET}"
    echo -e "  🌐  Studio:  ${CYAN}https://${CF_SUBDOMAIN_STUDIO}.${CF_DOMAIN}${RESET}"
    echo -e "  🌐  Coolify: ${CYAN}https://${CF_SUBDOMAIN_COOLIFY}.${CF_DOMAIN}${RESET}"
    echo ""
    echo -e "${BOLD}Start the tunnel:${RESET}  ${YELLOW}bash scripts/colony.sh start${RESET}"
}

# =============================================================================
# SECTION C: TAILSCALE SETUP (--tailscale)
# =============================================================================

install_tailscale() {
    step "C1: Install Tailscale"

    if command -v tailscale &>/dev/null; then
        success "Tailscale already installed: $(tailscale version | head -1)"
        return 0
    fi

    info "Installing Tailscale via official script..."
    curl -fsSL https://tailscale.com/install.sh | sh
    command -v tailscale &>/dev/null || fatal "Tailscale installation failed."
    success "Tailscale installed: $(tailscale version | head -1)"
}

start_tailscale_daemon() {
    step "C2: Start Tailscale Daemon"

    if tailscale status &>/dev/null; then
        success "Tailscale daemon already running."
        return 0
    fi

    info "Starting tailscaled..."
    if command -v systemctl &>/dev/null && systemctl is-active --quiet tailscaled 2>/dev/null; then
        success "tailscaled running via systemd."
    else
        sudo tailscaled \
            --state=/var/lib/tailscale/tailscaled.state \
            --socket=/run/tailscale/tailscaled.sock \
            &>/tmp/tailscaled.log &
        sleep 3
        tailscale status &>/dev/null || fatal "tailscaled did not start. Check /tmp/tailscaled.log"
        success "tailscaled started."
    fi
}

connect_tailscale() {
    step "C3: Connect to Tailscale Network"

    if tailscale status 2>/dev/null | grep -q "^[0-9]"; then
        local TSIP; TSIP="$(tailscale ip --4 2>/dev/null || echo 'unknown')"
        success "Already connected — Tailscale IP: ${TSIP}"
        return 0
    fi

    info "Opening Tailscale login..."
    info "If running headless WSL, copy the URL shown and open it in Windows browser."
    echo ""
    sudo tailscale up --accept-routes

    local ELAPSED=0
    while [[ $ELAPSED -lt 60 ]]; do
        if tailscale status 2>/dev/null | grep -q "^[0-9]"; then
            local TSIP; TSIP="$(tailscale ip --4 2>/dev/null || echo 'unknown')"
            success "Connected! Tailscale IP: ${TSIP}"
            return 0
        fi
        sleep 3; (( ELAPSED += 3 )) || true; echo -n "."
    done
    echo ""
    warn "Tailscale connection timed out. Check browser and try again."
}

configure_tailscale_routing() {
    step "C4: Subnet Routing"

    local WSL_IP; WSL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '')"
    if [[ -n "$WSL_IP" ]]; then
        local SUBNET="${WSL_IP%.*}.0/24"
        info "Advertising WSL subnet ${SUBNET} to Tailscale..."
        sudo tailscale up --advertise-routes="${SUBNET}" --accept-routes 2>/dev/null \
            || warn "Subnet routing may require approval in Tailscale admin console."
        info "Go to https://login.tailscale.com/admin/machines to enable route approval."
    fi
}

update_tailscale_env() {
    local TSIP; TSIP="$(tailscale ip --4 2>/dev/null || echo 'not-connected')"
    local ENV_LOCAL="${BACKEND_DIR}/.env.local"

    if [[ -f "$ENV_LOCAL" ]]; then
        if grep -q "TAILSCALE_IP=" "$ENV_LOCAL"; then
            sed -i "s|TAILSCALE_IP=.*|TAILSCALE_IP=${TSIP}|" "$ENV_LOCAL"
        else
            echo "TAILSCALE_IP=${TSIP}" >> "$ENV_LOCAL"
        fi
    else
        echo "TAILSCALE_IP=${TSIP}" > "$ENV_LOCAL"
    fi
    success ".env.local updated: TAILSCALE_IP=${TSIP}"
}

print_tailscale_summary() {
    banner "Tailscale Setup Complete!"
    local TSIP; TSIP="$(tailscale ip --4 2>/dev/null || echo 'not-connected')"
    local WSL_IP; WSL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo '?')"

    echo -e "${GREEN}${BOLD}Your stable Tailscale IP: ${TSIP}${RESET}"
    echo ""
    echo -e "${BOLD}Use in Flutter for local device testing:${RESET}"
    echo -e "  API:             http://${TSIP}:${LOCAL_PORT_API:-3000}"
    echo -e "  Supabase Studio: http://${TSIP}:${LOCAL_PORT_STUDIO:-3002}"
    echo -e "  Coolify:         http://${TSIP}:${LOCAL_PORT_COOLIFY:-8000}"
    echo ""
    echo -e "${BOLD}Why Tailscale over WSL IP?${RESET}"
    echo -e "  WSL IP (${WSL_IP}) changes every restart."
    echo -e "  Tailscale IP (${TSIP}) NEVER changes."
    echo ""
    echo -e "${BOLD}Install Tailscale on your phone/device:${RESET}"
    echo -e "  Android: Play Store → Tailscale"
    echo -e "  iOS:     App Store → Tailscale"
    echo -e "  Log in with the same account — all devices see each other automatically."
}

# =============================================================================
# SECTION D: CHECK-ONLY MODE (--check)
# =============================================================================

run_check_only() {
    step "Prerequisite Check Only"
    local OK=true

    check_cmd() {
        if command -v "$1" &>/dev/null; then
            success "$1 ✓ ($(command -v "$1"))"
        else
            error "$1 ✗ — not found"
            OK=false
        fi
    }

    check_cmd curl; check_cmd git; check_cmd python3; check_cmd jq; check_cmd docker

    if docker info &>/dev/null 2>&1; then
        success "Docker daemon: running"
    else
        warn "Docker daemon: not running (sudo service docker start)"
        OK=false
    fi

    if docker ps 2>/dev/null | grep -q coolify; then
        local WSL_IP; WSL_IP="$(hostname -I | awk '{print $1}')"
        success "Coolify: running at http://${WSL_IP}:8000"
    else
        warn "Coolify: not running"
    fi

    if command -v cloudflared &>/dev/null; then
        success "cloudflared: $(cloudflared --version)"
    else
        warn "cloudflared: not installed (run: colony-setup.sh --cloudflare)"
    fi

    if command -v tailscale &>/dev/null && tailscale status &>/dev/null 2>&1; then
        local TSIP; TSIP="$(tailscale ip --4 2>/dev/null || echo 'unknown')"
        success "Tailscale: connected (${TSIP})"
    else
        warn "Tailscale: not connected (optional)"
    fi

    $OK && echo -e "\n${GREEN}${BOLD}All required tools present.${RESET}" \
         || echo -e "\n${YELLOW}${BOLD}Some items missing — run colony-setup.sh to install.${RESET}"
}

# =============================================================================
# MAIN DISPATCH
# =============================================================================

MODE="${1:-full}"

case "$MODE" in
    --cloudflare|-c)
        banner "Colony — Cloudflare Tunnel Setup"
        install_cloudflared
        authenticate_cloudflare
        create_tunnel
        write_tunnel_config
        create_dns_records
        write_env_tunnel
        print_cloudflare_summary
        ;;

    --tailscale|-t)
        banner "Colony — Tailscale Setup"
        install_tailscale
        start_tailscale_daemon
        connect_tailscale
        configure_tailscale_routing
        update_tailscale_env
        print_tailscale_summary
        ;;

    --check|-k)
        banner "Colony — Prerequisite Check"
        run_check_only
        ;;

    full|"")
        banner "Colony — Full Development Environment Setup"
        echo -e "Started at: $(date)"
        echo ""
        check_prerequisites
        install_docker
        install_coolify
        deploy_supabase
        wait_for_services
        setup_database
        print_full_summary
        ;;

    --schema|-s)
        banner "Colony — Apply Database Schema"
        APPLY_SCRIPT="${SCRIPT_DIR}/apply-schema.sh"
        if [[ ! -f "$APPLY_SCRIPT" ]]; then
            fatal "apply-schema.sh not found at ${APPLY_SCRIPT}"
        fi
        # Pass --verify flag if given as second arg
        SCHEMA_FLAG="${2:-}"
        if [[ "$SCHEMA_FLAG" == "--verify" ]]; then
            bash "$APPLY_SCRIPT" --verify
        else
            bash "$APPLY_SCRIPT"
        fi
        ;;

    --help|-h|help)
        echo ""
        echo -e "${BOLD}${CYAN}Colony Intelligent Installer${RESET}  — colony-setup.sh"
        echo ""
        echo -e "${BOLD}Usage:${RESET}"
        echo -e "  bash scripts/colony-setup.sh              ${CYAN}# Full fresh setup (idempotent)${RESET}"
        echo -e "  bash scripts/colony-setup.sh --cloudflare ${CYAN}# Wire Cloudflare tunnel + DNS (run once)${RESET}"
        echo -e "  bash scripts/colony-setup.sh --tailscale  ${CYAN}# Install & connect Tailscale (optional)${RESET}"
        echo -e "  bash scripts/colony-setup.sh --check      ${CYAN}# Check prerequisites, no installs${RESET}"
        echo -e "  bash scripts/colony-setup.sh --schema     ${CYAN}# Apply DB migrations + seeds (Phase 1.1)${RESET}"
        echo -e "  bash scripts/colony-setup.sh --schema --verify ${CYAN}# Apply DB + run verify-schema.sh${RESET}"
        echo -e "  bash scripts/colony-setup.sh --help       ${CYAN}# Show this help${RESET}"
        echo ""
        echo -e "${BOLD}What each mode does:${RESET}"
        echo -e "  ${GREEN}(no flag)${RESET}      Runs full setup in order:"
        echo -e "               A1 Prerequisites → A2 Docker → A3 Coolify → A4 Supabase → A5 Health wait → A6 DB setup"
        echo -e "               Each step is idempotent — already-installed tools are skipped."
        echo ""
        echo -e "  ${GREEN}--cloudflare${RESET}   One-time Cloudflare tunnel wiring:"
        echo -e "               B1 Install cloudflared → B2 Authenticate → B3 Create tunnel"
        echo -e "               B4 Write config.yml → B5 Create DNS CNAMEs → B6 Write .env.tunnel"
        echo ""
        echo -e "  ${GREEN}--tailscale${RESET}    Tailscale setup for stable device IP:"
        echo -e "               C1 Install Tailscale → C2 Start daemon → C3 Authenticate"
        echo -e "               C4 Configure subnet routing → Update .env.local"
        echo ""
        echo -e "  ${GREEN}--check${RESET}        Prerequisite check only (curl, git, python3, jq, docker)"
        echo -e "               No installs — just reports what is/isn't present."
        echo ""
        echo -e "${BOLD}Generated files:${RESET}"
        echo -e "  backend/.env.local   WSL IP and local URLs  (every colony.sh start)"
        echo -e "  backend/.env.tunnel  Permanent public URLs  (colony-setup.sh --cloudflare)"
        echo ""
        echo -e "${BOLD}Daily workflow (after first-time setup):${RESET}"
        echo -e "  bash scripts/colony.sh start   ${CYAN}# start tunnel + services${RESET}"
        echo -e "  bash scripts/colony.sh status  ${CYAN}# health check${RESET}"
        echo ""
        exit 0
        ;;

    *)
        error "Unknown flag: ${MODE}"
        echo "Run: bash scripts/colony-setup.sh --help"
        exit 1
        ;;
esac
