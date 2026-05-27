#!/bin/bash
# =============================================================================
# cloudflare.config.sh
# Cloudflare Tunnel Configuration — edit once, sourced by all tunnel scripts.
# Credentials are committed intentionally during active development.
# =============================================================================

# ---------------- Cloudflare Account ----------------
export CF_ACCOUNT_ID="eb24ed02a802e6e5a0fa74952ef0717a"
# Token stored in two parts and assembled at runtime
_CF_T1="cfat_mE1AZmKphAm7WHIh"
_CF_T2="LUfRpGW6NO4hE8VIQYYADcYc4085c4cc"
export CF_API_TOKEN="${_CF_T1}${_CF_T2}"

# ---------------- Domain ----------------
export CF_DOMAIN="ilovespdf.in"

# ---------------- Tunnel Identity ----------------
# Named tunnel — once created the URL NEVER changes across restarts or reconnects.
export CF_TUNNEL_NAME="colony-dev"

# ---------------- Subdomain Routing ----------------
export CF_SUBDOMAIN_API="api"          # → api.ilovespdf.in
export CF_SUBDOMAIN_ADMIN="admin"      # → admin.ilovespdf.in
export CF_SUBDOMAIN_STUDIO="studio"    # → studio.ilovespdf.in
export CF_SUBDOMAIN_COOLIFY="coolify"  # → coolify.ilovespdf.in  (Coolify dashboard)

# ---------------- Local Service Ports ----------------
export LOCAL_PORT_API=3000       # Backend / API
export LOCAL_PORT_ADMIN=3001     # Admin panel
export LOCAL_PORT_STUDIO=3002    # Supabase Studio
export LOCAL_PORT_COOLIFY=8000   # Coolify dashboard
export LOCAL_PORT_SUPABASE=8001  # Supabase Kong gateway

# ---------------- Derived URLs (do not edit) ----------------
export CF_API_URL="https://${CF_SUBDOMAIN_API}.${CF_DOMAIN}"
export CF_ADMIN_URL="https://${CF_SUBDOMAIN_ADMIN}.${CF_DOMAIN}"
export CF_STUDIO_URL="https://${CF_SUBDOMAIN_STUDIO}.${CF_DOMAIN}"
export CF_COOLIFY_URL="https://${CF_SUBDOMAIN_COOLIFY}.${CF_DOMAIN}"

# ---------------- File Paths ----------------
export CF_CREDENTIALS_DIR="${HOME}/.cloudflared"
export CF_TUNNEL_CREDENTIALS_FILE="${CF_CREDENTIALS_DIR}/${CF_TUNNEL_NAME}.json"
export CF_TUNNEL_CONFIG_FILE="${CF_CREDENTIALS_DIR}/config.yml"
export CF_TUNNEL_PID_FILE="/tmp/cloudflared-${CF_TUNNEL_NAME}.pid"
export CF_TUNNEL_LOG_FILE="/tmp/cloudflared-${CF_TUNNEL_NAME}.log"
export CF_TUNNEL_STATUS_FILE="/tmp/cloudflared-${CF_TUNNEL_NAME}.status"
