#!/bin/bash
# =============================================================================
# cloudflare-setup.sh  —  Run ONCE to permanently wire up the tunnel.
# Installs cloudflared, authenticates, creates named tunnel, configures
# DNS records via API, and writes .env.tunnel to the backend root.
#
# Usage (in WSL):  bash scripts/cloudflare-setup.sh
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

# ── Step 1: Install cloudflared ────────────────────────────────────────────────
install_cloudflared() {
    banner "Step 1: Installing cloudflared"
    if command -v cloudflared &>/dev/null; then
        success "cloudflared already installed: $(cloudflared --version)"; return 0
    fi
    if [[ -f /etc/os-release ]]; then source /etc/os-release; DISTRO="${ID:-unknown}"; else DISTRO="unknown"; fi
    case "$DISTRO" in
        ubuntu|debian|linuxmint|pop|kali)
            sudo apt-get update -qq
            sudo apt-get install -y -qq curl gnupg lsb-release
            curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
                | sudo gpg --dearmor -o /usr/share/keyrings/cloudflare-main.gpg
            echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
                | sudo tee /etc/apt/sources.list.d/cloudflared.list > /dev/null
            sudo apt-get update -qq && sudo apt-get install -y cloudflared ;;
        fedora|centos|rhel|rocky|almalinux)
            sudo rpm --import https://pkg.cloudflare.com/cloudflare-main.gpg
            curl -fsSL https://pkg.cloudflare.com/cloudflared-ascii.repo | sudo tee /etc/yum.repos.d/cloudflared.repo > /dev/null
            sudo dnf install -y cloudflared ;;
        *)
            warn "Unknown distro. Falling back to binary install."
            ARCH="$(uname -m)"
            case "$ARCH" in
                x86_64)  URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" ;;
                aarch64) URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64" ;;
                *)       fatal "Unsupported architecture: $ARCH" ;;
            esac
            curl -fsSL "$URL" -o /tmp/cloudflared
            sudo install -m755 /tmp/cloudflared /usr/local/bin/cloudflared
            rm -f /tmp/cloudflared ;;
    esac
    command -v cloudflared &>/dev/null || fatal "Installation failed."
    success "Installed: $(cloudflared --version)"
}

# ── Step 2: Authenticate ───────────────────────────────────────────────────────
authenticate_cloudflare() {
    banner "Step 2: Cloudflare Authentication"
    if [[ -f "${CF_CREDENTIALS_DIR}/cert.pem" ]]; then
        success "Already authenticated."; return 0
    fi
    info "Opening browser for Cloudflare login — click Authorize for ${CF_DOMAIN}..."
    cloudflared tunnel login
    [[ -f "${CF_CREDENTIALS_DIR}/cert.pem" ]] || fatal "Auth failed — cert.pem not created."
    success "Authenticated!"
}

# ── Step 3: Create named tunnel ────────────────────────────────────────────────
create_tunnel() {
    banner "Step 3: Creating Named Tunnel"
    if cloudflared tunnel list 2>/dev/null | grep -q "\b${CF_TUNNEL_NAME}\b"; then
        success "Tunnel '${CF_TUNNEL_NAME}' already exists."; return 0
    fi
    cloudflared tunnel create "${CF_TUNNEL_NAME}"
    [[ -f "$CF_TUNNEL_CREDENTIALS_FILE" ]] || fatal "Credentials file not created."
    success "Tunnel '${CF_TUNNEL_NAME}' created!"
}

# ── Step 4: Write config.yml ───────────────────────────────────────────────────
write_tunnel_config() {
    banner "Step 4: Writing Tunnel Config"
    TUNNEL_ID="$(python3 -c "import json; d=json.load(open('${CF_TUNNEL_CREDENTIALS_FILE}')); print(d.get('TunnelID',d.get('tunnelID',d.get('tunnel_id',''))))" 2>/dev/null || true)"
    if [[ -z "$TUNNEL_ID" ]]; then
        TUNNEL_ID="$(cloudflared tunnel list --output json 2>/dev/null | python3 -c "import json,sys; [print(t['id']) for t in json.load(sys.stdin) if t.get('name')=='${CF_TUNNEL_NAME}']" 2>/dev/null || true)"
    fi
    [[ -n "$TUNNEL_ID" ]] || fatal "Cannot determine tunnel ID."
    info "Tunnel ID: ${TUNNEL_ID}"
    mkdir -p "$CF_CREDENTIALS_DIR"
    cat > "$CF_TUNNEL_CONFIG_FILE" <<CFEOF
# cloudflared config — auto-generated by cloudflare-setup.sh
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

# ── Step 5: DNS records ────────────────────────────────────────────────────────
create_dns_records() {
    banner "Step 5: Creating DNS CNAME Records"
    ZONE_RESP="$(curl -sSf "https://api.cloudflare.com/client/v4/zones?name=${CF_DOMAIN}&status=active" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json")"
    ZONE_ID="$(echo "$ZONE_RESP" | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2>/dev/null || true)"
    [[ -n "$ZONE_ID" ]] || fatal "Cannot resolve Zone ID for ${CF_DOMAIN}. Check API token Zone:Read permission."
    info "Zone ID: ${ZONE_ID}"

    TUNNEL_ID="$(python3 -c "import json; d=json.load(open('${CF_TUNNEL_CREDENTIALS_FILE}')); print(d.get('TunnelID',d.get('tunnelID','')))" 2>/dev/null || true)"
    CNAME_TARGET="${TUNNEL_ID}.cfargotunnel.com"
    info "CNAME target: ${CNAME_TARGET}"

    SUBDOMAINS=("$CF_SUBDOMAIN_API" "$CF_SUBDOMAIN_ADMIN" "$CF_SUBDOMAIN_STUDIO" "$CF_SUBDOMAIN_COOLIFY")
    for SUB in "${SUBDOMAINS[@]}"; do
        FULL="${SUB}.${CF_DOMAIN}"
        EXISTING_ID="$(curl -sSf "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records?type=CNAME&name=${FULL}" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" \
            | python3 -c "import json,sys; r=json.load(sys.stdin).get('result',[]); print(r[0]['id'] if r else '')" 2>/dev/null || true)"
        PAYLOAD="{\"type\":\"CNAME\",\"name\":\"${FULL}\",\"content\":\"${CNAME_TARGET}\",\"proxied\":true,\"comment\":\"colony-dev auto-managed\"}"
        if [[ -n "$EXISTING_ID" ]]; then
            RESP="$(curl -sSf -X PUT "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records/${EXISTING_ID}" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "$PAYLOAD")"
            OK="$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success',False))" 2>/dev/null)"
            [[ "$OK" == "True" ]] && success "Updated: ${FULL}" || warn "Update failed for ${FULL}: ${RESP}"
        else
            RESP="$(curl -sSf -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" -H "Content-Type: application/json" --data "$PAYLOAD")"
            OK="$(echo "$RESP" | python3 -c "import json,sys; print(json.load(sys.stdin).get('success',False))" 2>/dev/null)"
            [[ "$OK" == "True" ]] && success "Created: ${FULL}" || error "Failed: ${FULL} — ${RESP}"
        fi
    done
}

# ── Step 6: Write .env.tunnel ──────────────────────────────────────────────────
write_env_tunnel() {
    banner "Step 6: Writing .env.tunnel"
    cat > "${BACKEND_DIR}/.env.tunnel" <<ENVEOF
# .env.tunnel — auto-generated by cloudflare-setup.sh
# These URLs are PERMANENT — they survive all restarts, NAT changes, and IP changes.
# Source this file:  source backend/.env.tunnel
# Flutter build:     --dart-define-from-file=backend/.env.tunnel

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

print_summary() {
    banner "Setup Complete!"
    echo -e "${GREEN}${BOLD}Permanent URLs (never change):${RESET}"
    echo -e "  🌐  API:     ${CYAN}https://${CF_SUBDOMAIN_API}.${CF_DOMAIN}${RESET}"
    echo -e "  🌐  Admin:   ${CYAN}https://${CF_SUBDOMAIN_ADMIN}.${CF_DOMAIN}${RESET}"
    echo -e "  🌐  Studio:  ${CYAN}https://${CF_SUBDOMAIN_STUDIO}.${CF_DOMAIN}${RESET}"
    echo -e "  🌐  Coolify: ${CYAN}https://${CF_SUBDOMAIN_COOLIFY}.${CF_DOMAIN}${RESET}"
    echo ""
    echo -e "${YELLOW}Next:${RESET} bash scripts/tunnel.sh start"
}

main() {
    banner "Colony — Cloudflare Permanent Tunnel Setup"
    install_cloudflared
    authenticate_cloudflare
    create_tunnel
    write_tunnel_config
    create_dns_records
    write_env_tunnel
    print_summary
}
main "$@"
