#!/bin/bash
# =============================================================================
# setup.sh — Colony Full Development Environment Setup
# Idempotent: safe to run multiple times. Detects what exists and skips it.
#
# What this does (in order):
#   1. Verify/install system prerequisites (curl, git, python3, jq)
#   2. Install Docker Engine (not Desktop) with WSL auto-start
#   3. Install Coolify
#   4. Deploy Supabase self-hosted via Docker Compose
#   5. Wait for all services to be healthy
#   6. Run database migrations and seed initial data
#   7. Print the complete URL summary
#
# Usage (in WSL):  bash backend/scripts/setup.sh
# =============================================================================

set -euo pipefail

# ── Colours ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
fatal()   { error "$*"; exit 1; }
step()    { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}\n"; }
banner()  { echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════╗${RESET}"; \
            echo -e "${BOLD}${CYAN}║  $*${RESET}"; \
            echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${RESET}\n"; }

# ── Paths ───────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"
SUPABASE_DIR="${BACKEND_DIR}/docker/supabase"
source "${SCRIPT_DIR}/cloudflare.config.sh"

SETUP_LOG="/tmp/colony-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$SETUP_LOG") 2>&1
info "Logging to ${SETUP_LOG}"

# ── Helper: retry a command ──────────────────────────────────────────────────────
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

# ── Step 1: Prerequisites ────────────────────────────────────────────────────────
check_prerequisites() {
    step "Step 1: System Prerequisites"

    # Ensure we are in WSL
    if ! grep -qi microsoft /proc/version 2>/dev/null; then
        warn "This script is designed for WSL (Linux). Detected: $(uname -r)"
        warn "Continue at your own risk."
    else
        success "WSL detected: $(grep -i microsoft /proc/version | head -1)"
    fi

    # Required tools
    local MISSING=()
    for cmd in curl git python3 jq; do
        if command -v "$cmd" &>/dev/null; then
            success "$cmd: $(command -v "$cmd")"
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

# ── Step 2: Docker Engine ────────────────────────────────────────────────────────
install_docker() {
    step "Step 2: Docker Engine"

    if command -v docker &>/dev/null && docker info &>/dev/null; then
        success "Docker already running: $(docker --version)"
        return 0
    fi

    if command -v docker &>/dev/null; then
        info "Docker installed but not running. Attempting to start..."
        sudo service docker start 2>/dev/null || sudo dockerd &>/tmp/dockerd.log &
        sleep 5
        docker info &>/dev/null && { success "Docker started."; return 0; } || true
    fi

    info "Installing Docker Engine (official method)..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

    # Add Docker GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    sudo apt-get update -qq
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add current user to docker group (avoid sudo for docker commands)
    sudo usermod -aG docker "$USER"
    info "Added ${USER} to docker group. You may need to run: newgrp docker"

    # Start Docker daemon
    sudo service docker start || sudo dockerd &>/tmp/dockerd.log &
    sleep 5

    # Configure Docker to start with WSL
    if ! grep -q "service docker start" "${HOME}/.bashrc" 2>/dev/null; then
        echo '# Colony: auto-start Docker' >> "${HOME}/.bashrc"
        echo 'sudo service docker start 2>/dev/null || true' >> "${HOME}/.bashrc"
        info "Added Docker auto-start to ~/.bashrc"
    fi

    docker info &>/dev/null || fatal "Docker failed to start. Check /tmp/dockerd.log"
    success "Docker Engine installed: $(docker --version)"

    # Install docker compose standalone as fallback
    if ! command -v docker-compose &>/dev/null; then
        info "Installing docker compose standalone..."
        COMPOSE_VERSION="$(curl -sSf https://api.github.com/repos/docker/compose/releases/latest | grep '"tag_name"' | cut -d'"' -f4)"
        sudo curl -fsSL "https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" \
            -o /usr/local/bin/docker-compose
        sudo chmod +x /usr/local/bin/docker-compose
        success "docker-compose installed: $(docker-compose --version)"
    fi
}

# ── Step 3: Coolify ─────────────────────────────────────────────────────────────
install_coolify() {
    step "Step 3: Coolify"

    # Check if Coolify containers are already running
    if docker ps 2>/dev/null | grep -q "coolify"; then
        WSL_IP="$(hostname -I | awk '{print $1}')"
        success "Coolify already running at http://${WSL_IP}:8000"
        return 0
    fi

    info "Installing Coolify via official script..."
    info "This will pull ~500MB of Docker images — may take a few minutes..."

    # Official Coolify install
    curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash

    # Wait for Coolify to be ready
    local WSL_IP; WSL_IP="$(hostname -I | awk '{print $1}')"
    info "Waiting for Coolify to start at http://${WSL_IP}:8000..."
    local ELAPSED=0
    while [[ $ELAPSED -lt 120 ]]; do
        if curl -sSf --max-time 5 "http://${WSL_IP}:8000" &>/dev/null; then
            success "Coolify is running at http://${WSL_IP}:8000"
            info "Public URL (via tunnel): ${CF_COOLIFY_URL}"
            return 0
        fi
        sleep 5; (( ELAPSED += 5 )) || true; echo -n "."
    done
    echo ""
    warn "Coolify did not respond in 120s. Check: docker ps | grep coolify"
    warn "Try manually: docker compose -f /data/coolify/source/docker-compose.yml ps"
}

# ── Step 4: Supabase via Docker Compose ─────────────────────────────────────────
deploy_supabase() {
    step "Step 4: Supabase Self-Hosted"

    [[ -f "${SUPABASE_DIR}/docker-compose.yml" ]] \
        || fatal "Supabase docker-compose.yml not found at ${SUPABASE_DIR}"

    ENV_FILE="${SUPABASE_DIR}/.env.supabase"
    [[ -f "$ENV_FILE" ]] || fatal ".env.supabase not found at ${ENV_FILE}"

    # Check if already running
    if docker compose -f "${SUPABASE_DIR}/docker-compose.yml" \
        --env-file "$ENV_FILE" ps 2>/dev/null | grep -q "running"; then
        success "Supabase containers already running."
        return 0
    fi

    # Pull images first
    info "Pulling Supabase Docker images (first run ~2GB, subsequent runs cached)..."
    docker compose -f "${SUPABASE_DIR}/docker-compose.yml" \
        --env-file "$ENV_FILE" pull

    # Start all services
    info "Starting Supabase services..."
    docker compose -f "${SUPABASE_DIR}/docker-compose.yml" \
        --env-file "$ENV_FILE" up -d

    success "Supabase containers started."
}

# ── Step 5: Wait for health ──────────────────────────────────────────────────────
wait_for_services() {
    step "Step 5: Waiting for Services to be Healthy"

    ENV_FILE="${SUPABASE_DIR}/.env.supabase"
    local MAX_WAIT=300
    local ELAPSED=0

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
        ALL_HEALTHY=true
        for CONTAINER in "${!SERVICES[@]}"; do
            STATUS="$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")"
            if [[ "$STATUS" != "healthy" ]]; then
                ALL_HEALTHY=false
            fi
        done

        if $ALL_HEALTHY; then
            success "All services are healthy!"
            break
        fi

        sleep 5; (( ELAPSED += 5 )) || true
        echo -n "."
    done
    echo ""

    # Print final status
    for CONTAINER in "${!SERVICES[@]}"; do
        STATUS="$(docker inspect --format='{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "missing")"
        LABEL="${SERVICES[$CONTAINER]}"
        case "$STATUS" in
            healthy)   echo -e "  ${GREEN}✓${RESET}  ${LABEL} (${CONTAINER})" ;;
            starting)  echo -e "  ${YELLOW}~${RESET}  ${LABEL} — still starting" ;;
            unhealthy) echo -e "  ${RED}✗${RESET}  ${LABEL} — UNHEALTHY" ;;
            missing)   echo -e "  ${RED}✗${RESET}  ${LABEL} — container not found" ;;
            *)         echo -e "  ${YELLOW}?${RESET}  ${LABEL} — ${STATUS}" ;;
        esac
    done
}

# ── Step 6: Database setup ───────────────────────────────────────────────────────
setup_database() {
    step "Step 6: Database Configuration"

    # Wait for PostgreSQL to accept connections
    local RETRIES=0
    while ! docker exec colony-db pg_isready -U postgres &>/dev/null; do
        [[ $RETRIES -lt 30 ]] || fatal "PostgreSQL not ready after 150s."
        sleep 5; (( RETRIES++ )) || true; echo -n "."
    done
    echo ""
    success "PostgreSQL accepting connections."

    # Verify extensions
    info "Verifying extensions..."
    local EXTS="uuid-ossp postgis pg_trgm pgcrypto"
    for EXT in $EXTS; do
        RESULT="$(docker exec colony-db psql -U postgres -tAc \
            "SELECT COUNT(*) FROM pg_extension WHERE extname = '${EXT}';" 2>/dev/null || echo "0")"
        if [[ "$RESULT" == "1" ]]; then
            success "Extension ${EXT}: installed"
        else
            warn "Extension ${EXT}: not installed (will be installed via init SQL on first boot)"
        fi
    done

    # Create initial colony schema marker (idempotent)
    docker exec colony-db psql -U postgres -c \
        "CREATE TABLE IF NOT EXISTS public._colony_meta (
            key TEXT PRIMARY KEY,
            value TEXT,
            created_at TIMESTAMPTZ DEFAULT NOW()
        );" &>/dev/null || true

    # Mark setup as complete
    docker exec colony-db psql -U postgres -c \
        "INSERT INTO public._colony_meta (key, value) VALUES ('setup_version', '1.0')
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, created_at = NOW();" &>/dev/null || true

    success "Database configured."
}

# ── Step 7: Print summary ────────────────────────────────────────────────────────
print_summary() {
    WSL_IP="$(hostname -I | awk '{print $1}')"

    banner "Colony Dev Environment Ready!"

    echo -e "${BOLD}Local URLs (WSL network):${RESET}"
    echo -e "  Coolify:         ${CYAN}http://${WSL_IP}:${LOCAL_PORT_COOLIFY}${RESET}"
    echo -e "  Supabase Studio: ${CYAN}http://${WSL_IP}:${LOCAL_PORT_STUDIO}${RESET}"
    echo -e "  Supabase API:    ${CYAN}http://${WSL_IP}:${LOCAL_PORT_SUPABASE}${RESET}"
    echo ""

    if [[ -f "${BACKEND_DIR}/.env.tunnel" ]]; then
        source "${BACKEND_DIR}/.env.tunnel"
        echo -e "${BOLD}Permanent Public URLs:${RESET}"
        echo -e "  API:     ${CYAN}${API_URL}${RESET}"
        echo -e "  Admin:   ${CYAN}${ADMIN_URL}${RESET}"
        echo -e "  Studio:  ${CYAN}${STUDIO_URL}${RESET}"
        echo -e "  Coolify: ${CYAN}${COOLIFY_URL}${RESET}"
        echo ""
    else
        warn ".env.tunnel not found — run scripts/cloudflare-setup.sh to get permanent URLs"
    fi

    echo -e "${BOLD}Next steps:${RESET}"
    echo -e "  1. Open Coolify:         ${CYAN}http://${WSL_IP}:${LOCAL_PORT_COOLIFY}${RESET}"
    echo -e "     Create admin account on first visit"
    echo -e "  2. Start the tunnel:     ${YELLOW}bash scripts/tunnel.sh start${RESET}"
    echo -e "  3. Verify everything:    ${YELLOW}bash scripts/verify.sh${RESET}"
    echo -e "  4. (Optional) Tailscale: ${YELLOW}bash scripts/tailscale-setup.sh${RESET}"
    echo ""
    echo -e "${BOLD}Supabase Studio:${RESET}"
    echo -e "  URL: ${CYAN}http://${WSL_IP}:${LOCAL_PORT_STUDIO}${RESET}"
    echo -e "  From here: create tables, run SQL, manage auth, view storage"
    echo ""
    echo -e "${GREEN}${BOLD}Setup complete!${RESET}  Log saved to: ${SETUP_LOG}"
}

# ── Main ─────────────────────────────────────────────────────────────────────────
main() {
    banner "Colony — Full Dev Environment Setup"
    echo -e "Started at: $(date)"
    echo ""

    check_prerequisites
    install_docker
    install_coolify
    deploy_supabase
    wait_for_services
    setup_database
    print_summary
}
main "$@"
