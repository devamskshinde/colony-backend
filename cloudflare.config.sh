#!/usr/bin/env bash
# Public Colony backend configuration.
# Secrets are loaded from cloudflare.secrets.sh or environment variables.

CF_DOMAIN="ilovespdf.in"
CF_TUNNEL_NAME="colony-backend"
CF_ACCOUNT_ID="eb24ed02a802e6e5a0fa74952ef0717a"

CF_API_SUBDOMAIN="api"
CF_ADMIN_SUBDOMAIN="admin"
CF_STUDIO_SUBDOMAIN="studio"

# Recommended with Coolify: Cloudflare Tunnel hits Coolify's local proxy on
# port 80, and Coolify routes api/admin/studio by hostname.
CF_ROUTE_MODE="coolify-proxy"
CF_COOLIFY_PROXY_SCHEME="http"
CF_COOLIFY_PROXY_PORT="80"

# If you later choose direct-port mode, update these three once Coolify shows
# the host ports for each resource. Do not use 8000 for API unless you move
# the Coolify dashboard away from its default port.
CF_API_PORT="8080"
CF_ADMIN_PORT="3000"
CF_STUDIO_PORT="54323"

CF_ORIGIN_HOST="127.0.0.1"
CF_API_SCHEME="http"
CF_ADMIN_SCHEME="http"
CF_STUDIO_SCHEME="http"

CF_DNS_PROXIED="true"
CF_REQUIRE_LOCAL_PORTS="0"
CF_AUTO_INSTALL_DEPS="0"
CF_AUTO_INSTALL_CLOUDFLARED="0"

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

COOLIFY_DASHBOARD_PORT="8000"
COOLIFY_INSTALL_URL="https://cdn.coollabs.io/coolify/install.sh"
COOLIFY_FORCE_INSTALL="0"

COOLIFY_ROOT_USERNAME=""
COOLIFY_ROOT_EMAIL=""
COOLIFY_ROOT_PASSWORD=""

TAILSCALE_HOSTNAME="colony-backend-wsl"
TAILSCALE_ACCEPT_DNS="false"
