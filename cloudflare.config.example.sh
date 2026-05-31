#!/usr/bin/env bash
# Copy this file to cloudflare.config.sh and fill it once.
# cloudflare.config.sh is intentionally ignored because it contains an API token.

CF_DOMAIN="example.com"
CF_TUNNEL_NAME="colony-backend"
CF_ACCOUNT_ID="00000000000000000000000000000000"
CF_API_TOKEN="paste-cloudflare-api-token-here"

CF_API_SUBDOMAIN="api"
CF_ADMIN_SUBDOMAIN="admin"
CF_STUDIO_SUBDOMAIN="studio"

# Recommended with Coolify: point Cloudflare Tunnel at Coolify's local proxy.
# Then configure the same domains inside Coolify resources.
CF_ROUTE_MODE="coolify-proxy"
CF_COOLIFY_PROXY_SCHEME="http"
CF_COOLIFY_PROXY_PORT="80"

# Used when CF_ROUTE_MODE="ports", or for local health checks/documentation.
CF_API_PORT="8080"
CF_ADMIN_PORT="3000"
CF_STUDIO_PORT="54323"

# Usually keep these defaults for services running on the same WSL machine.
CF_ORIGIN_HOST="127.0.0.1"
CF_API_SCHEME="http"
CF_ADMIN_SCHEME="http"
CF_STUDIO_SCHEME="http"

# Tunnel and DNS behavior.
CF_DNS_PROXIED="true"
CF_REQUIRE_LOCAL_PORTS="0"
CF_AUTO_INSTALL_DEPS="0"
CF_AUTO_INSTALL_CLOUDFLARED="0"

# Network timeout/retry knobs.
CF_CURL_CONNECT_TIMEOUT="10"
CF_CURL_MAX_TIME="60"
CF_CURL_RETRIES="5"
CF_CURL_RETRY_DELAY="2"
CF_ORIGIN_CONNECT_TIMEOUT="30s"
CF_ORIGIN_TLS_TIMEOUT="10s"
CF_ORIGIN_TCP_KEEPALIVE="30s"
CF_ORIGIN_KEEPALIVE_TIMEOUT="90s"
CF_ORIGIN_KEEPALIVE_CONNECTIONS="100"
CF_ORIGIN_NO_TLS_VERIFY="false"
CF_ORIGIN_DISABLE_CHUNKED_ENCODING="false"

# Coolify local install/status behavior.
COOLIFY_DASHBOARD_PORT="8000"
COOLIFY_INSTALL_URL="https://cdn.coollabs.io/coolify/install.sh"
COOLIFY_FORCE_INSTALL="0"

# Optional: set these only if you want the Coolify installer to pre-create
# the first admin user. Otherwise leave them empty and register in the browser.
COOLIFY_ROOT_USERNAME=""
COOLIFY_ROOT_EMAIL=""
COOLIFY_ROOT_PASSWORD=""

# Optional Tailscale device-testing mode. TAILSCALE_AUTHKEY is a secret; keep
# it only in the ignored cloudflare.config.sh if you use it.
TAILSCALE_HOSTNAME="colony-backend-wsl"
TAILSCALE_AUTHKEY=""
TAILSCALE_ACCEPT_DNS="false"
