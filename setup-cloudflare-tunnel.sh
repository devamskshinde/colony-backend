#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
CONFIG_FILE="${CLOUDFLARE_CONFIG:-$SCRIPT_DIR/cloudflare.config.sh}"
SECRETS_FILE="${CLOUDFLARE_SECRETS:-$SCRIPT_DIR/cloudflare.secrets.sh}"
ENV_FILE="${TUNNEL_ENV_FILE:-$SCRIPT_DIR/.env.tunnel}"
STATE_DIR="$SCRIPT_DIR/.cloudflared"
LOG_DIR="$SCRIPT_DIR/logs"
CF_API_BASE="${CF_API_BASE:-https://api.cloudflare.com/client/v4}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
fi

log() { printf '%s\n' "${C_BLUE}==>${C_RESET} $*" >&2; }
ok() { printf '%s\n' "${C_GREEN}ok${C_RESET}  $*" >&2; }
warn() { printf '%s\n' "${C_YELLOW}warn${C_RESET} $*" >&2; }
die() { printf '%s\n' "${C_RED}error${C_RESET} $*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '%s\n' "${C_RED}error${C_RESET} Unexpected failure near line ${BASH_LINENO[0]}. Run '$0 doctor' for diagnostics." >&2
  exit "$exit_code"
}
trap on_error ERR

usage() {
  cat <<'USAGE'
Usage:
  ./setup-cloudflare-tunnel.sh all                Install/check Coolify, create tunnel/DNS, write env files
  ./setup-cloudflare-tunnel.sh install-coolify    Install or verify Coolify inside Linux/WSL
  ./setup-cloudflare-tunnel.sh configure-secrets  Prompt for local-only secrets
  ./setup-cloudflare-tunnel.sh setup              Create/update tunnel, DNS, and .env.tunnel
  ./setup-cloudflare-tunnel.sh tunnel             Choose Cloudflare, Tailscale, or direct IP interactively
  ./setup-cloudflare-tunnel.sh run                Run cloudflared in the foreground
  ./setup-cloudflare-tunnel.sh service-install    Install autostart service or WSL scheduled task
  ./setup-cloudflare-tunnel.sh install-cloudflared Install cloudflared on Linux/WSL
  ./setup-cloudflare-tunnel.sh tailscale          Install/connect Tailscale and write .env.tunnel
  ./setup-cloudflare-tunnel.sh verify             Verify Cloudflare tunnel, DNS records, and local ports
  ./setup-cloudflare-tunnel.sh coolify-status     Check Coolify dashboard and containers
  ./setup-cloudflare-tunnel.sh wsl-ip             Print WSL IP and update .env.local
  ./setup-cloudflare-tunnel.sh direct-ip          Print public IP and direct-port notes
  ./setup-cloudflare-tunnel.sh coolify-guide      Print exact Coolify Supabase/Redis setup notes
  ./setup-cloudflare-tunnel.sh doctor             Print environment diagnostics
  ./setup-cloudflare-tunnel.sh print-env          Print the generated API URL values
  ./setup-cloudflare-tunnel.sh help               Show this help

The script sources cloudflare.config.sh, then writes .env.tunnel after setup.
Secrets are read from cloudflare.secrets.sh or environment variables.
USAGE
}

have() { command -v "$1" >/dev/null 2>&1; }

run_root() {
  if [[ "${EUID:-$(id -u)}" == "0" ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

bool_json() {
  case "${1,,}" in
    1|yes|true|on) printf 'true' ;;
    0|no|false|off) printf 'false' ;;
    *) die "Expected boolean true/false, got '$1'" ;;
  esac
}

urlencode() {
  jq -rn --arg v "$1" '$v|@uri'
}

normalize_domain() {
  local value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  value="${value%.}"
  printf '%s' "$value" | tr '[:upper:]' '[:lower:]'
}

fqdn() {
  local subdomain="$1"
  if [[ -z "$subdomain" || "$subdomain" == "@" ]]; then
    printf '%s' "$CF_DOMAIN_NORMALIZED"
  elif [[ "$subdomain" == *".${CF_DOMAIN_NORMALIZED}" ]]; then
    printf '%s' "$subdomain"
  else
    printf '%s.%s' "$subdomain" "$CF_DOMAIN_NORMALIZED"
  fi
}

origin_url() {
  local scheme="$1" port="$2"
  printf '%s://%s:%s' "$scheme" "${CF_ORIGIN_HOST:-127.0.0.1}" "$port"
}

service_url_for() {
  local role="$1"
  case "$CF_ROUTE_MODE" in
    coolify-proxy)
      origin_url "$CF_COOLIFY_PROXY_SCHEME" "$CF_COOLIFY_PROXY_PORT"
      ;;
    ports)
      case "$role" in
        api) origin_url "$CF_API_SCHEME" "$CF_API_PORT" ;;
        admin) origin_url "$CF_ADMIN_SCHEME" "$CF_ADMIN_PORT" ;;
        studio) origin_url "$CF_STUDIO_SCHEME" "$CF_STUDIO_PORT" ;;
        *) die "Unknown service role '$role'" ;;
      esac
      ;;
    *)
      die "CF_ROUTE_MODE must be 'coolify-proxy' or 'ports', got '$CF_ROUTE_MODE'"
      ;;
  esac
}

coolify_dashboard_url() {
  local ip="${1:-127.0.0.1}"
  printf 'http://%s:%s' "$ip" "$COOLIFY_DASHBOARD_PORT"
}

source_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Missing $CONFIG_FILE. Copy cloudflare.config.example.sh to cloudflare.config.sh and fill it in."
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  if [[ -f "$SECRETS_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$SECRETS_FILE"
  fi

  : "${CF_DOMAIN:?CF_DOMAIN is required}"
  : "${CF_TUNNEL_NAME:?CF_TUNNEL_NAME is required}"
  : "${CF_ACCOUNT_ID:?CF_ACCOUNT_ID is required}"
  CF_API_TOKEN="${CF_API_TOKEN:-}"
  : "${CF_API_SUBDOMAIN:?CF_API_SUBDOMAIN is required}"
  : "${CF_ADMIN_SUBDOMAIN:?CF_ADMIN_SUBDOMAIN is required}"
  : "${CF_STUDIO_SUBDOMAIN:?CF_STUDIO_SUBDOMAIN is required}"
  : "${CF_API_PORT:?CF_API_PORT is required}"
  : "${CF_ADMIN_PORT:?CF_ADMIN_PORT is required}"
  : "${CF_STUDIO_PORT:?CF_STUDIO_PORT is required}"

  CF_DOMAIN_NORMALIZED="$(normalize_domain "$CF_DOMAIN")"
  CF_ORIGIN_HOST="${CF_ORIGIN_HOST:-127.0.0.1}"
  CF_API_SCHEME="${CF_API_SCHEME:-http}"
  CF_ADMIN_SCHEME="${CF_ADMIN_SCHEME:-http}"
  CF_STUDIO_SCHEME="${CF_STUDIO_SCHEME:-http}"
  CF_ROUTE_MODE="${CF_ROUTE_MODE:-ports}"
  CF_COOLIFY_PROXY_SCHEME="${CF_COOLIFY_PROXY_SCHEME:-http}"
  CF_COOLIFY_PROXY_PORT="${CF_COOLIFY_PROXY_PORT:-80}"
  CF_DNS_PROXIED="${CF_DNS_PROXIED:-true}"
  CF_REQUIRE_LOCAL_PORTS="${CF_REQUIRE_LOCAL_PORTS:-0}"
  CF_AUTO_INSTALL_DEPS="${CF_AUTO_INSTALL_DEPS:-0}"
  CF_AUTO_INSTALL_CLOUDFLARED="${CF_AUTO_INSTALL_CLOUDFLARED:-0}"
  CF_CURL_CONNECT_TIMEOUT="${CF_CURL_CONNECT_TIMEOUT:-10}"
  CF_CURL_MAX_TIME="${CF_CURL_MAX_TIME:-60}"
  CF_CURL_RETRIES="${CF_CURL_RETRIES:-5}"
  CF_CURL_RETRY_DELAY="${CF_CURL_RETRY_DELAY:-2}"
  CF_ORIGIN_CONNECT_TIMEOUT="${CF_ORIGIN_CONNECT_TIMEOUT:-30s}"
  CF_ORIGIN_TLS_TIMEOUT="${CF_ORIGIN_TLS_TIMEOUT:-10s}"
  CF_ORIGIN_TCP_KEEPALIVE="${CF_ORIGIN_TCP_KEEPALIVE:-30s}"
  CF_ORIGIN_KEEPALIVE_TIMEOUT="${CF_ORIGIN_KEEPALIVE_TIMEOUT:-90s}"
  CF_ORIGIN_KEEPALIVE_CONNECTIONS="${CF_ORIGIN_KEEPALIVE_CONNECTIONS:-100}"
  CF_ORIGIN_NO_TLS_VERIFY="${CF_ORIGIN_NO_TLS_VERIFY:-false}"
  CF_ORIGIN_DISABLE_CHUNKED_ENCODING="${CF_ORIGIN_DISABLE_CHUNKED_ENCODING:-false}"
  COOLIFY_DASHBOARD_PORT="${COOLIFY_DASHBOARD_PORT:-8000}"
  COOLIFY_INSTALL_URL="${COOLIFY_INSTALL_URL:-https://cdn.coollabs.io/coolify/install.sh}"
  COOLIFY_FORCE_INSTALL="${COOLIFY_FORCE_INSTALL:-0}"
  COOLIFY_ROOT_USERNAME="${COOLIFY_ROOT_USERNAME:-}"
  COOLIFY_ROOT_EMAIL="${COOLIFY_ROOT_EMAIL:-}"
  COOLIFY_ROOT_PASSWORD="${COOLIFY_ROOT_PASSWORD:-}"
  TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-colony-backend-wsl}"
  TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"
  TAILSCALE_ACCEPT_DNS="${TAILSCALE_ACCEPT_DNS:-false}"

  API_HOSTNAME="$(fqdn "$CF_API_SUBDOMAIN")"
  ADMIN_HOSTNAME="$(fqdn "$CF_ADMIN_SUBDOMAIN")"
  STUDIO_HOSTNAME="$(fqdn "$CF_STUDIO_SUBDOMAIN")"
  API_URL="https://$API_HOSTNAME"
  ADMIN_PANEL_URL="https://$ADMIN_HOSTNAME"
  SUPABASE_STUDIO_URL="https://$STUDIO_HOSTNAME"
}

source_tunnel_env_if_present() {
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
  fi
}

shell_quote() {
  printf '%q' "$1"
}

write_secret_assignment() {
  local key="$1" value="$2"
  if [[ ! -f "$SECRETS_FILE" ]]; then
    cat >"$SECRETS_FILE" <<'EOF'
#!/usr/bin/env bash
# Local secrets for Colony backend. This file is ignored by git.

EOF
  fi
  printf '%s=%s\n' "$key" "$(shell_quote "$value")" >>"$SECRETS_FILE"
  chmod 600 "$SECRETS_FILE" 2>/dev/null || true
}

ensure_cloudflare_token() {
  local force_prompt="${1:-0}"
  if [[ -n "${CF_API_TOKEN:-}" && "$force_prompt" != "1" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    die "Missing CF_API_TOKEN. Run './setup-cloudflare-tunnel.sh configure-secrets' on this device or export CF_API_TOKEN."
  fi

  warn "Cloudflare API token is required for tunnel/DNS commands."
  if [[ -n "${CF_API_TOKEN:-}" ]]; then
    printf 'Paste new Cloudflare API token (blank keeps current, input hidden): ' >&2
  else
    printf 'Paste Cloudflare API token (input hidden): ' >&2
  fi
  local token save_choice
  IFS= read -r -s token
  printf '\n' >&2
  if [[ -z "$token" && -n "${CF_API_TOKEN:-}" ]]; then
    ok "Keeping existing CF_API_TOKEN"
    return 0
  fi
  [[ -n "$token" ]] || die "Cloudflare API token cannot be empty."
  CF_API_TOKEN="$token"

  printf 'Save it to %s for this device? [Y/n]: ' "$SECRETS_FILE" >&2
  IFS= read -r save_choice
  case "${save_choice:-Y}" in
    y|Y|yes|YES)
      write_secret_assignment "CF_API_TOKEN" "$CF_API_TOKEN"
      ok "Saved CF_API_TOKEN to $SECRETS_FILE"
      ;;
    *)
      warn "Token kept only for this run."
      ;;
  esac
}

configure_secrets() {
  source_config
  ensure_cloudflare_token 1

  if [[ -t 0 ]]; then
    printf 'Optional Tailscale auth key for unattended setup (blank to skip, input hidden): ' >&2
    local ts_key
    IFS= read -r -s ts_key
    printf '\n' >&2
    if [[ -n "$ts_key" ]]; then
      TAILSCALE_AUTHKEY="$ts_key"
      write_secret_assignment "TAILSCALE_AUTHKEY" "$TAILSCALE_AUTHKEY"
      ok "Saved TAILSCALE_AUTHKEY to $SECRETS_FILE"
    fi
  fi
}

install_missing_deps_if_allowed() {
  local missing=("$@")
  (( ${#missing[@]} == 0 )) && return 0

  if [[ "$CF_AUTO_INSTALL_DEPS" == "1" && "$(uname -s)" == "Linux" && -r /etc/os-release ]] && grep -qiE 'ubuntu|debian' /etc/os-release; then
    log "Installing missing dependencies: ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y "${missing[@]}"
    return 0
  fi

  die "Missing required commands: ${missing[*]}. On Ubuntu/WSL run: sudo apt-get update && sudo apt-get install -y ${missing[*]}"
}

ensure_core_deps() {
  local missing=()
  have curl || missing+=(curl)
  have jq || missing+=(jq)
  have openssl || missing+=(openssl)
  install_missing_deps_if_allowed "${missing[@]}"
}

cf_api() {
  ensure_cloudflare_token
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local url="$CF_API_BASE$endpoint"
  local response http_code response_body
  local -a args

  args=(
    --silent
    --show-error
    --location
    --request "$method"
    --header "Authorization: Bearer $CF_API_TOKEN"
    --header "Content-Type: application/json"
    --connect-timeout "$CF_CURL_CONNECT_TIMEOUT"
    --max-time "$CF_CURL_MAX_TIME"
    --retry "$CF_CURL_RETRIES"
    --retry-delay "$CF_CURL_RETRY_DELAY"
    --write-out $'\n%{http_code}'
  )
  if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
    args+=(--retry-all-errors)
  fi
  if curl --help all 2>/dev/null | grep -q -- '--retry-connrefused'; then
    args+=(--retry-connrefused)
  fi
  [[ -z "$body" ]] || args+=(--data "$body")

  response="$(curl "${args[@]}" "$url")" || die "Cloudflare API request failed: $method $endpoint"
  http_code="${response##*$'\n'}"
  response_body="${response%$'\n'*}"

  if ! jq -e . >/dev/null 2>&1 <<<"$response_body"; then
    die "Cloudflare returned non-JSON response for $method $endpoint (HTTP $http_code)."
  fi
  if [[ "$http_code" -lt 200 || "$http_code" -ge 300 ]]; then
    print_cf_errors "$response_body"
    die "Cloudflare API returned HTTP $http_code for $method $endpoint."
  fi
  if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$response_body"; then
    print_cf_errors "$response_body"
    die "Cloudflare API reported success=false for $method $endpoint."
  fi

  printf '%s' "$response_body"
}

print_cf_errors() {
  local body="$1"
  local messages
  messages="$(jq -r '(.errors // [])[]? | "- code \(.code): \(.message)"' <<<"$body")"
  [[ -n "$messages" ]] && printf '%s\n' "$messages" >&2
}

check_cloudflare_token_nonfatal() {
  if [[ -z "${CF_API_TOKEN:-}" ]]; then
    warn "Cloudflare API token is missing. Put CF_API_TOKEN in $SECRETS_FILE or export it before setup."
    return 1
  fi
  local response http_code response_body messages
  response="$(
    curl --silent --show-error --location \
      --header "Authorization: Bearer $CF_API_TOKEN" \
      --header "Content-Type: application/json" \
      --connect-timeout "$CF_CURL_CONNECT_TIMEOUT" \
      --max-time "$CF_CURL_MAX_TIME" \
      --write-out $'\n%{http_code}' \
      "$CF_API_BASE/user/tokens/verify" 2>&1 || true
  )"
  if [[ -z "$response" ]]; then
    warn "Cloudflare API token check did not return a response"
    return 1
  fi
  http_code="${response##*$'\n'}"
  response_body="${response%$'\n'*}"
  if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]] && jq -e '.success == true' >/dev/null 2>&1 <<<"$response_body"; then
    ok "Cloudflare API token verified"
    return 0
  fi
  warn "Cloudflare API token check failed with HTTP $http_code"
  if jq -e . >/dev/null 2>&1 <<<"$response_body"; then
    messages="$(jq -r '(.errors // [])[]? | "- code \(.code): \(.message)"' <<<"$response_body")"
    [[ -n "$messages" ]] && printf '%s\n' "$messages" >&2
  else
    printf '%s\n' "$response_body" >&2
  fi
  return 1
}

resolve_zone_id() {
  local name_encoded endpoint response zone_id count
  name_encoded="$(urlencode "$CF_DOMAIN_NORMALIZED")"
  endpoint="/zones?name=$name_encoded&status=active&per_page=50"
  response="$(cf_api GET "$endpoint")"
  count="$(jq --arg domain "$CF_DOMAIN_NORMALIZED" '[.result[] | select(.name == $domain)] | length' <<<"$response")"
  if [[ "$count" == "0" ]]; then
    die "No active Cloudflare zone found for $CF_DOMAIN_NORMALIZED. Make sure the domain is added to Cloudflare and uses Cloudflare DNS."
  fi
  if [[ "$count" != "1" ]]; then
    die "Found multiple zones for $CF_DOMAIN_NORMALIZED. Please set a unique domain/account in cloudflare.config.sh."
  fi
  zone_id="$(jq -r --arg domain "$CF_DOMAIN_NORMALIZED" '.result[] | select(.name == $domain) | .id' <<<"$response")"
  printf '%s' "$zone_id"
}

find_tunnel_id() {
  local response tunnel_id
  response="$(cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel?is_deleted=false&per_page=1000")"
  tunnel_id="$(jq -r --arg name "$CF_TUNNEL_NAME" '.result[]? | select(.name == $name and (.deleted_at == null)) | .id' <<<"$response" | head -n 1)"
  printf '%s' "$tunnel_id"
}

create_tunnel() {
  local secret payload response tunnel_id
  secret="$(openssl rand -base64 32)"
  payload="$(jq -n --arg name "$CF_TUNNEL_NAME" --arg secret "$secret" '{name:$name, config_src:"cloudflare", tunnel_secret:$secret}')"
  response="$(cf_api POST "/accounts/$CF_ACCOUNT_ID/cfd_tunnel" "$payload")"
  tunnel_id="$(jq -r '.result.id' <<<"$response")"
  [[ -n "$tunnel_id" && "$tunnel_id" != "null" ]] || die "Cloudflare did not return a tunnel id."
  printf '%s' "$tunnel_id"
}

get_or_create_tunnel() {
  local tunnel_id
  tunnel_id="$(find_tunnel_id)"
  if [[ -n "$tunnel_id" ]]; then
    ok "Using existing tunnel '$CF_TUNNEL_NAME' ($tunnel_id)"
  else
    log "Creating remote-managed tunnel '$CF_TUNNEL_NAME'"
    tunnel_id="$(create_tunnel)"
    ok "Created tunnel '$CF_TUNNEL_NAME' ($tunnel_id)"
  fi
  printf '%s' "$tunnel_id"
}

put_tunnel_config() {
  local tunnel_id="$1"
  local payload response
  payload="$(
    jq -n \
      --arg apiHost "$API_HOSTNAME" \
      --arg adminHost "$ADMIN_HOSTNAME" \
      --arg studioHost "$STUDIO_HOSTNAME" \
      --arg apiService "$(service_url_for api)" \
      --arg adminService "$(service_url_for admin)" \
      --arg studioService "$(service_url_for studio)" \
      --arg connectTimeout "$CF_ORIGIN_CONNECT_TIMEOUT" \
      --arg tlsTimeout "$CF_ORIGIN_TLS_TIMEOUT" \
      --arg tcpKeepAlive "$CF_ORIGIN_TCP_KEEPALIVE" \
      --arg keepAliveTimeout "$CF_ORIGIN_KEEPALIVE_TIMEOUT" \
      --arg keepAliveConnections "$CF_ORIGIN_KEEPALIVE_CONNECTIONS" \
      --argjson noTLSVerify "$(bool_json "$CF_ORIGIN_NO_TLS_VERIFY")" \
      --argjson disableChunkedEncoding "$(bool_json "$CF_ORIGIN_DISABLE_CHUNKED_ENCODING")" \
      '{
        config: {
          originRequest: {
            connectTimeout: $connectTimeout,
            tlsTimeout: $tlsTimeout,
            tcpKeepAlive: $tcpKeepAlive,
            keepAliveTimeout: $keepAliveTimeout,
            keepAliveConnections: ($keepAliveConnections | tonumber),
            noTLSVerify: $noTLSVerify,
            disableChunkedEncoding: $disableChunkedEncoding
          },
          ingress: [
            {hostname: $apiHost, service: $apiService},
            {hostname: $adminHost, service: $adminService},
            {hostname: $studioHost, service: $studioService},
            {service: "http_status:404"}
          ]
        }
      }'
  )"
  response="$(cf_api PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$tunnel_id/configurations" "$payload")"
  jq -e '.result' >/dev/null <<<"$response"
  ok "Updated tunnel ingress: $API_HOSTNAME, $ADMIN_HOSTNAME, $STUDIO_HOSTNAME"
}

find_dns_record_id() {
  local zone_id="$1"
  local hostname="$2"
  local name_encoded response
  name_encoded="$(urlencode "$hostname")"
  response="$(cf_api GET "/zones/$zone_id/dns_records?type=CNAME&name.exact=$name_encoded&match=all&per_page=100")"
  jq -r --arg hostname "$hostname" '.result[]? | select(.type == "CNAME" and .name == $hostname) | .id' <<<"$response" | head -n 1
}

upsert_dns_record() {
  local zone_id="$1"
  local hostname="$2"
  local target="$3"
  local record_id payload endpoint method
  local proxied

  proxied="$(bool_json "$CF_DNS_PROXIED")"
  payload="$(jq -n --arg name "$hostname" --arg content "$target" --argjson proxied "$proxied" \
    '{type:"CNAME", name:$name, content:$content, ttl:1, proxied:$proxied, comment:"Managed by Colony backend Cloudflare tunnel setup"}')"

  record_id="$(find_dns_record_id "$zone_id" "$hostname")"
  if [[ -n "$record_id" ]]; then
    method="PATCH"
    endpoint="/zones/$zone_id/dns_records/$record_id"
  else
    method="POST"
    endpoint="/zones/$zone_id/dns_records"
  fi

  cf_api "$method" "$endpoint" "$payload" >/dev/null
  ok "DNS $hostname -> $target"
}

port_is_open() {
  local host="$1" port="$2"
  if have nc; then
    nc -z -w 2 "$host" "$port" >/dev/null 2>&1
    return $?
  fi
  if have timeout; then
    timeout 2 bash -c ":</dev/tcp/$host/$port" >/dev/null 2>&1
    return $?
  fi
  bash -c ":</dev/tcp/$host/$port" >/dev/null 2>&1
}

check_local_ports() {
  local failed=0

  log "Checking local origin ports on $CF_ORIGIN_HOST"
  if [[ "$CF_ROUTE_MODE" == "coolify-proxy" ]]; then
    if port_is_open "$CF_ORIGIN_HOST" "$CF_COOLIFY_PROXY_PORT"; then
      ok "Coolify proxy origin is reachable at $(origin_url "$CF_COOLIFY_PROXY_SCHEME" "$CF_COOLIFY_PROXY_PORT")"
    else
      failed=1
      warn "Coolify proxy is not listening at $(origin_url "$CF_COOLIFY_PROXY_SCHEME" "$CF_COOLIFY_PROXY_PORT")"
    fi
    if port_is_open "$CF_ORIGIN_HOST" "$COOLIFY_DASHBOARD_PORT"; then
      ok "Coolify dashboard is reachable at $(coolify_dashboard_url "$CF_ORIGIN_HOST")"
    else
      warn "Coolify dashboard is not listening at $(coolify_dashboard_url "$CF_ORIGIN_HOST")"
    fi
  else
    local labels ports schemes
    labels=("API" "Admin panel" "Supabase Studio")
    ports=("$CF_API_PORT" "$CF_ADMIN_PORT" "$CF_STUDIO_PORT")
    schemes=("$CF_API_SCHEME" "$CF_ADMIN_SCHEME" "$CF_STUDIO_SCHEME")
    for i in "${!ports[@]}"; do
      if port_is_open "$CF_ORIGIN_HOST" "${ports[$i]}"; then
        ok "${labels[$i]} origin is reachable at ${schemes[$i]}://$CF_ORIGIN_HOST:${ports[$i]}"
      else
        failed=1
        warn "${labels[$i]} origin is not listening at ${schemes[$i]}://$CF_ORIGIN_HOST:${ports[$i]}"
      fi
    done
  fi

  if [[ "$failed" == "1" && "$CF_REQUIRE_LOCAL_PORTS" == "1" ]]; then
    die "One or more local ports are closed and CF_REQUIRE_LOCAL_PORTS=1."
  fi
  if [[ "$failed" == "1" ]]; then
    warn "Continuing because CF_REQUIRE_LOCAL_PORTS=0. DNS/tunnel can be prepared before Coolify resources are running."
  fi
}

write_env_file() {
  local tunnel_id="$1"
  local target="$2"
  mkdir -p "$STATE_DIR"
  local tmp="$ENV_FILE.tmp"
  cat >"$tmp" <<EOF
# Generated by setup-cloudflare-tunnel.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Source this file from backend scripts and Flutter build wrappers.

export TUNNEL_DOMAIN="$CF_DOMAIN_NORMALIZED"
export TUNNEL_NAME="$CF_TUNNEL_NAME"
export TUNNEL_ID="$tunnel_id"
export TUNNEL_TARGET="$target"
export TUNNEL_METHOD="cloudflare"
export TUNNEL_ROUTE_MODE="$CF_ROUTE_MODE"

export API_SUBDOMAIN="$CF_API_SUBDOMAIN"
export ADMIN_SUBDOMAIN="$CF_ADMIN_SUBDOMAIN"
export SUPABASE_STUDIO_SUBDOMAIN="$CF_STUDIO_SUBDOMAIN"

export API_URL="$API_URL"
export API_BASE_URL="$API_URL"
export COLONY_API_URL="$API_URL"
export FLUTTER_API_URL="$API_URL"
export ADMIN_PANEL_URL="$ADMIN_PANEL_URL"
export SUPABASE_STUDIO_URL="$SUPABASE_STUDIO_URL"
export COOLIFY_DASHBOARD_URL="$(coolify_dashboard_url "$(detect_wsl_ip)")"
export COOLIFY_LOOPBACK_URL="$(coolify_dashboard_url "127.0.0.1")"
export TAILSCALE_IP=""
export PUBLIC_IP=""
EOF
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE"
}

get_tunnel_token() {
  local tunnel_id="$1"
  local response token
  response="$(cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$tunnel_id/token")"
  token="$(jq -r '.result' <<<"$response")"
  [[ -n "$token" && "$token" != "null" ]] || die "Cloudflare did not return a tunnel token."
  printf '%s' "$token"
}

ensure_cloudflared() {
  if have cloudflared; then
    return 0
  fi
  if [[ "$CF_AUTO_INSTALL_CLOUDFLARED" == "1" ]]; then
    install_cloudflared
    return 0
  fi
  die "cloudflared is not installed. Run: ./setup-cloudflare-tunnel.sh install-cloudflared"
}

install_cloudflared() {
  if have cloudflared; then
    ok "cloudflared already installed: $(cloudflared --version 2>/dev/null || true)"
    return 0
  fi
  [[ "$(uname -s)" == "Linux" ]] || die "Automatic cloudflared install is only implemented for Linux/WSL."
  have curl || die "curl is required before installing cloudflared."
  have sudo || die "sudo is required to install cloudflared."

  local arch deb_arch url tmpdir
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) deb_arch="amd64" ;;
    aarch64|arm64) deb_arch="arm64" ;;
    armv7l) deb_arch="arm" ;;
    *) die "Unsupported architecture for automatic cloudflared install: $arch" ;;
  esac

  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$deb_arch.deb"
  tmpdir="$(mktemp -d)"
  log "Downloading cloudflared package"
  curl --fail --location --show-error --silent --connect-timeout 10 --max-time 120 -o "$tmpdir/cloudflared.deb" "$url"
  sudo dpkg -i "$tmpdir/cloudflared.deb" || {
    warn "dpkg reported dependency issues; asking apt to fix them."
    sudo apt-get install -f -y
  }
  rm -rf "$tmpdir"
  have cloudflared || die "cloudflared install did not place the binary on PATH."
  ok "Installed $(cloudflared --version 2>/dev/null || printf 'cloudflared')"
}

is_linux() {
  [[ "$(uname -s 2>/dev/null || true)" == "Linux" ]]
}

detect_wsl_ip() {
  local ip=""
  if have hostname; then
    ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+\.' | grep -v '^127\.' | head -n 1 || true)"
  fi
  if [[ -z "$ip" ]] && have ip; then
    ip="$(ip -4 addr show eth0 2>/dev/null | awk '/inet / { sub(/\/.*/, "", $2); print $2; exit }' || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="127.0.0.1"
  fi
  printf '%s' "$ip"
}

write_local_env() {
  local wsl_ip="$1"
  local env_local="$SCRIPT_DIR/.env.local"
  local tmp="$env_local.tmp"
  cat >"$tmp" <<EOF
# Generated by setup-cloudflare-tunnel.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# This file is local machine state; WSL IPs can change after restart.

export WSL_IP="$wsl_ip"
export COOLIFY_DASHBOARD_PORT="$COOLIFY_DASHBOARD_PORT"
export COOLIFY_DASHBOARD_URL="$(coolify_dashboard_url "$wsl_ip")"
export COOLIFY_LOOPBACK_URL="$(coolify_dashboard_url "127.0.0.1")"
export COOLIFY_PROXY_URL="$(origin_url "$CF_COOLIFY_PROXY_SCHEME" "$CF_COOLIFY_PROXY_PORT")"
EOF
  mv "$tmp" "$env_local"
  chmod 600 "$env_local" 2>/dev/null || true
  ok "Wrote $env_local"
}

print_wsl_ip() {
  source_config
  local wsl_ip
  wsl_ip="$(detect_wsl_ip)"
  write_local_env "$wsl_ip"
  printf 'WSL_IP=%s\n' "$wsl_ip"
  printf 'COOLIFY_DASHBOARD_URL=%s\n' "$(coolify_dashboard_url "$wsl_ip")"
}

wait_for_http() {
  local url="$1"
  local timeout_seconds="${2:-180}"
  local start now code
  start="$(date +%s)"
  while true; do
    code="$(curl --silent --output /dev/null --write-out '%{http_code}' --connect-timeout 3 --max-time 10 "$url" 2>/dev/null || true)"
    if [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout_seconds )); then
      return 1
    fi
    sleep 3
  done
}

start_docker_if_possible() {
  have docker || return 1
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if have systemctl && [[ -d /run/systemd/system ]]; then
    sudo systemctl start docker >/dev/null 2>&1 || true
  fi
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if have service; then
    sudo service docker start >/dev/null 2>&1 || true
  fi
  docker info >/dev/null 2>&1
}

docker_ps() {
  if docker ps >/dev/null 2>&1; then
    docker ps "$@"
  elif have sudo; then
    sudo docker ps "$@"
  else
    docker ps "$@"
  fi
}

coolify_installed() {
  [[ -f /data/coolify/source/docker-compose.yml || -f /data/coolify/source/docker-compose.prod.yml ]]
}

install_coolify() {
  source_config
  is_linux || die "Coolify install must run inside Linux/WSL, not native Windows PowerShell."
  have curl || die "curl is required. On Ubuntu run: sudo apt-get update && sudo apt-get install -y curl"
  have sudo || [[ "$EUID" == "0" ]] || die "sudo is required unless running as root."

  local wsl_ip installer_env=()
  wsl_ip="$(detect_wsl_ip)"
  write_local_env "$wsl_ip"

  if coolify_installed && [[ "$COOLIFY_FORCE_INSTALL" != "1" ]]; then
    ok "Coolify files already exist under /data/coolify"
    start_docker_if_possible || warn "Docker is not running yet. Start Docker, then rerun coolify-status."
  else
    [[ -n "$COOLIFY_ROOT_USERNAME" ]] && installer_env+=("ROOT_USERNAME=$COOLIFY_ROOT_USERNAME")
    [[ -n "$COOLIFY_ROOT_EMAIL" ]] && installer_env+=("ROOT_USER_EMAIL=$COOLIFY_ROOT_EMAIL")
    [[ -n "$COOLIFY_ROOT_PASSWORD" ]] && installer_env+=("ROOT_USER_PASSWORD=$COOLIFY_ROOT_PASSWORD")

    log "Installing Coolify with the official installer"
    if [[ "$EUID" == "0" ]]; then
      env "${installer_env[@]}" bash -c "curl -fsSL '$COOLIFY_INSTALL_URL' | bash"
    else
      sudo -E env "${installer_env[@]}" bash -c "curl -fsSL '$COOLIFY_INSTALL_URL' | bash"
    fi
  fi

  if wait_for_http "$(coolify_dashboard_url "127.0.0.1")" 180; then
    ok "Coolify dashboard is responding at $(coolify_dashboard_url "$wsl_ip")"
  else
    warn "Coolify dashboard did not respond within 180s. Run './setup-cloudflare-tunnel.sh coolify-status' for details."
  fi

  warn "Create the first Coolify admin immediately if you did not set COOLIFY_ROOT_* values."
  coolify_guide
}

coolify_status() {
  source_config
  local wsl_ip local_url
  wsl_ip="$(detect_wsl_ip)"
  local_url="$(coolify_dashboard_url "127.0.0.1")"
  write_local_env "$wsl_ip"

  if wait_for_http "$local_url" 5; then
    ok "Coolify dashboard: $(coolify_dashboard_url "$wsl_ip")"
  else
    warn "Coolify dashboard is not reachable at $local_url"
  fi

  if have docker && start_docker_if_possible; then
    log "Coolify-related containers"
    docker_ps --format '  {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E 'coolify|redis|postgres|supabase|traefik|caddy' || warn "No matching containers found yet."
  else
    warn "Docker is not installed or not running."
  fi
}

direct_ip_info() {
  source_config
  have curl || die "curl is required to detect public IP."
  local public_ip
  public_ip="$(curl --silent --show-error --location --connect-timeout 5 --max-time 15 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$public_ip" ]] || public_ip="$(curl --silent --show-error --location --connect-timeout 5 --max-time 15 https://ifconfig.me 2>/dev/null || true)"
  [[ -n "$public_ip" ]] || die "Could not detect public IP."

  write_direct_env "$public_ip"
  printf 'PUBLIC_IP=%s\n' "$public_ip"
  printf 'API_DIRECT_URL=http://%s:%s\n' "$public_ip" "$CF_API_PORT"
  printf 'ADMIN_DIRECT_URL=http://%s:%s\n' "$public_ip" "$CF_ADMIN_PORT"
  printf 'SUPABASE_STUDIO_DIRECT_URL=http://%s:%s\n' "$public_ip" "$CF_STUDIO_PORT"
  warn "Direct IP only works if your ISP/router gives you reachable inbound ports. Behind CGNAT or changing home IP, use Cloudflare Tunnel instead."
}

write_direct_env() {
  local public_ip="$1"
  local tmp="$ENV_FILE.tmp"
  cat >"$tmp" <<EOF
# Generated by setup-cloudflare-tunnel.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Direct IP mode is not stable behind CGNAT or changing home IPs.

export TUNNEL_METHOD="direct-ip"
export TUNNEL_DOMAIN="$CF_DOMAIN_NORMALIZED"
export TUNNEL_NAME="$CF_TUNNEL_NAME"
export TUNNEL_ID=""
export TUNNEL_TARGET="$public_ip"
export TUNNEL_ROUTE_MODE="ports"

export API_URL="http://$public_ip:$CF_API_PORT"
export API_BASE_URL="http://$public_ip:$CF_API_PORT"
export COLONY_API_URL="http://$public_ip:$CF_API_PORT"
export FLUTTER_API_URL="http://$public_ip:$CF_API_PORT"
export ADMIN_PANEL_URL="http://$public_ip:$CF_ADMIN_PORT"
export SUPABASE_STUDIO_URL="http://$public_ip:$CF_STUDIO_PORT"
export COOLIFY_DASHBOARD_URL="$(coolify_dashboard_url "$(detect_wsl_ip)")"
export COOLIFY_LOOPBACK_URL="$(coolify_dashboard_url "127.0.0.1")"
export TAILSCALE_IP=""
export PUBLIC_IP="$public_ip"
EOF
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE for direct IP mode"
}

install_tailscale_if_needed() {
  if have tailscale; then
    ok "Tailscale already installed: $(tailscale version 2>/dev/null | head -n 1 || printf tailscale)"
    return 0
  fi
  is_linux || die "Tailscale install must run inside Linux/WSL."
  have curl || die "curl is required before installing Tailscale."
  have sudo || [[ "$EUID" == "0" ]] || die "sudo is required unless running as root."

  log "Installing Tailscale with the official installer"
  if [[ "$EUID" == "0" ]]; then
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    curl -fsSL https://tailscale.com/install.sh | sudo sh
  fi
  have tailscale || die "Tailscale install did not place the binary on PATH."
}

start_tailscale_if_possible() {
  if tailscale status >/dev/null 2>&1; then
    return 0
  fi
  if have systemctl && [[ -d /run/systemd/system ]]; then
    run_root systemctl enable --now tailscaled >/dev/null 2>&1 || true
  fi
  if tailscale status >/dev/null 2>&1; then
    return 0
  fi
  if have service; then
    run_root service tailscaled start >/dev/null 2>&1 || true
  fi
  tailscale status >/dev/null 2>&1
}

tailscale_ip() {
  tailscale ip -4 2>/dev/null | head -n 1
}

write_tailscale_env() {
  local ts_ip="$1"
  local tmp="$ENV_FILE.tmp"
  cat >"$tmp" <<EOF
# Generated by setup-cloudflare-tunnel.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Tailscale mode is stable for devices in your tailnet.

export TUNNEL_METHOD="tailscale"
export TUNNEL_DOMAIN="$CF_DOMAIN_NORMALIZED"
export TUNNEL_NAME="$TAILSCALE_HOSTNAME"
export TUNNEL_ID=""
export TUNNEL_TARGET="$ts_ip"
export TUNNEL_ROUTE_MODE="ports"

export API_URL="http://$ts_ip:$CF_API_PORT"
export API_BASE_URL="http://$ts_ip:$CF_API_PORT"
export COLONY_API_URL="http://$ts_ip:$CF_API_PORT"
export FLUTTER_API_URL="http://$ts_ip:$CF_API_PORT"
export ADMIN_PANEL_URL="http://$ts_ip:$CF_ADMIN_PORT"
export SUPABASE_STUDIO_URL="http://$ts_ip:$CF_STUDIO_PORT"
export COOLIFY_DASHBOARD_URL="$(coolify_dashboard_url "$(detect_wsl_ip)")"
export COOLIFY_LOOPBACK_URL="$(coolify_dashboard_url "127.0.0.1")"
export TAILSCALE_IP="$ts_ip"
export PUBLIC_IP=""
EOF
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE for Tailscale mode"
}

tailscale_setup() {
  source_config
  install_tailscale_if_needed
  start_tailscale_if_possible || die "tailscaled is not running. Enable systemd in WSL or start the Tailscale service, then rerun this command."

  local up_args ts_ip
  up_args=(--hostname "$TAILSCALE_HOSTNAME" --accept-dns="$(bool_json "$TAILSCALE_ACCEPT_DNS")")
  if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
    up_args+=(--authkey "$TAILSCALE_AUTHKEY")
  fi

  if [[ -z "$(tailscale_ip)" ]]; then
    log "Connecting this WSL machine to Tailscale"
    run_root tailscale up "${up_args[@]}"
  else
    ok "Tailscale already has an IPv4 address"
  fi

  ts_ip="$(tailscale_ip)"
  [[ -n "$ts_ip" ]] || die "Tailscale did not report an IPv4 address."
  write_tailscale_env "$ts_ip"
  printf 'TAILSCALE_IP=%s\n' "$ts_ip"
  printf 'API_URL=http://%s:%s\n' "$ts_ip" "$CF_API_PORT"
  warn "For Tailscale mode, make sure the API/Admin/Studio services expose stable host ports in Coolify."
}

interactive_tunnel() {
  source_config
  cat >&2 <<EOF
Choose how to expose this backend:
  1) Cloudflare Tunnel - stable public HTTPS URLs, best default
  2) Tailscale - stable private URL for your own devices
  3) Direct public IP - only works with reachable router/firewall ports
EOF
  printf 'Enter 1, 2, or 3: ' >&2
  local choice
  read -r choice
  case "$choice" in
    1|cloudflare|Cloudflare)
      setup_tunnel
      run_tunnel
      ;;
    2|tailscale|Tailscale)
      tailscale_setup
      ;;
    3|direct|direct-ip)
      direct_ip_info
      ;;
    *)
      die "Unknown tunnel choice: $choice"
      ;;
  esac
}

coolify_guide() {
  source_config
  cat >&2 <<EOF

Coolify setup notes:
  1. Open Coolify: $(coolify_dashboard_url "$(detect_wsl_ip)")
  2. Add Supabase from New Resource -> Service -> Supabase.
  3. Add Redis from New Resource -> Database -> Redis.
  4. For HTTP resources, set domains inside Coolify:
       API endpoint:     $API_URL
       Admin panel:      $ADMIN_PANEL_URL
       Supabase Studio:  $SUPABASE_STUDIO_URL
  5. Keep Cloudflare tunnel mode as '$CF_ROUTE_MODE'. With coolify-proxy mode,
     Cloudflare sends all three public hostnames to $(origin_url "$CF_COOLIFY_PROXY_SCHEME" "$CF_COOLIFY_PROXY_PORT"),
     and Coolify routes them by hostname. No public IP or router port forwarding is needed.

Supabase database and Redis ports should stay private for development unless you explicitly need TCP access.
EOF
}

setup_all() {
  install_coolify
  setup_tunnel
  ok "All-in-one setup finished. Run './setup-cloudflare-tunnel.sh service-install' once to autostart cloudflared after restart."
}

setup_tunnel() {
  source_config
  ensure_core_deps
  check_local_ports

  log "Resolving Cloudflare zone for $CF_DOMAIN_NORMALIZED"
  local zone_id tunnel_id target
  zone_id="$(resolve_zone_id)"
  ok "Zone id resolved"

  tunnel_id="$(get_or_create_tunnel)"
  target="$tunnel_id.cfargotunnel.com"

  put_tunnel_config "$tunnel_id"
  upsert_dns_record "$zone_id" "$API_HOSTNAME" "$target"
  upsert_dns_record "$zone_id" "$ADMIN_HOSTNAME" "$target"
  upsert_dns_record "$zone_id" "$STUDIO_HOSTNAME" "$target"
  write_env_file "$tunnel_id" "$target"

  ok "Permanent URLs are ready:"
  printf '  API:             %s\n' "$API_URL" >&2
  printf '  Admin panel:     %s\n' "$ADMIN_PANEL_URL" >&2
  printf '  Supabase Studio: %s\n' "$SUPABASE_STUDIO_URL" >&2
  warn "Manual verification: Cloudflare dashboard -> $CF_DOMAIN_NORMALIZED -> DNS -> confirm the three CNAME records point to $target."
  warn "Run './setup-cloudflare-tunnel.sh service-install' to keep the connector alive after restart, or './setup-cloudflare-tunnel.sh run' for foreground mode."
}

run_tunnel() {
  source_config
  ensure_core_deps
  source_tunnel_env_if_present
  local tunnel_id="${TUNNEL_ID:-}"
  if [[ -z "$tunnel_id" ]]; then
    tunnel_id="$(find_tunnel_id)"
  fi
  [[ -n "$tunnel_id" ]] || die "No tunnel found. Run './setup-cloudflare-tunnel.sh setup' first."
  ensure_cloudflared
  local token
  token="$(get_tunnel_token "$tunnel_id")"
  log "Starting cloudflared for tunnel '$CF_TUNNEL_NAME'. Stop with Ctrl+C."
  exec cloudflared tunnel --no-autoupdate run --token "$token"
}

is_wsl() {
  [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null
}

service_install() {
  source_config
  ensure_core_deps
  source_tunnel_env_if_present
  local tunnel_id="${TUNNEL_ID:-}"
  [[ -n "$tunnel_id" ]] || tunnel_id="$(find_tunnel_id)"
  [[ -n "$tunnel_id" ]] || die "No tunnel found. Run './setup-cloudflare-tunnel.sh setup' first."
  ensure_cloudflared

  if is_wsl; then
    install_wsl_scheduled_task
    return 0
  fi

  if [[ "$(uname -s)" == "Linux" && -d /run/systemd/system ]] && have systemctl; then
    local token
    token="$(get_tunnel_token "$tunnel_id")"
    log "Installing cloudflared systemd service"
    sudo cloudflared service install "$token"
    sudo systemctl enable --now cloudflared
    ok "cloudflared system service is installed and running"
    return 0
  fi

  die "No supported autostart method detected. Use './setup-cloudflare-tunnel.sh run' or enable systemd in WSL."
}

install_wsl_scheduled_task() {
  have powershell.exe || die "powershell.exe not available from WSL. Run foreground mode or enable WSL interop."
  local distro task_name runner
  distro="${WSL_DISTRO_NAME:-}"
  [[ -n "$distro" ]] || die "WSL_DISTRO_NAME is missing; cannot create a Windows scheduled task safely."
  task_name="${CF_WSL_TASK_NAME:-ColonyCloudflareTunnel}"
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  runner="$STATE_DIR/run-cloudflared.sh"
  cat >"$runner" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
cd "$SCRIPT_DIR"
exec "$SCRIPT_PATH" run >> "$LOG_DIR/cloudflared.log" 2>&1
EOF
  chmod 700 "$runner"

  log "Registering Windows scheduled task '$task_name' for WSL distro '$distro'"
  CF_WSL_TASK_NAME="$task_name" CF_WSL_DISTRO="$distro" CF_WSL_RUNNER="$runner" powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '
$ErrorActionPreference = "Stop"
$action = New-ScheduledTaskAction -Execute "wsl.exe" -Argument "-d `"$env:CF_WSL_DISTRO`" -- bash `"$env:CF_WSL_RUNNER`""
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $env:CF_WSL_TASK_NAME -Action $action -Trigger $trigger -Settings $settings -Description "Colony backend Cloudflare tunnel connector" -Force | Out-Null
Start-ScheduledTask -TaskName $env:CF_WSL_TASK_NAME
'
  ok "Scheduled task installed. Logs: $LOG_DIR/cloudflared.log"
}

verify_dns_record() {
  local zone_id="$1" hostname="$2" expected="$3"
  local record_id response content
  record_id="$(find_dns_record_id "$zone_id" "$hostname")"
  [[ -n "$record_id" ]] || die "Missing CNAME record for $hostname"
  response="$(cf_api GET "/zones/$zone_id/dns_records/$record_id")"
  content="$(jq -r '.result.content' <<<"$response")"
  [[ "$content" == "$expected" ]] || die "$hostname points to $content, expected $expected"
  ok "Verified DNS record $hostname -> $expected"
}

docker_container_names() {
  docker_ps --format '{{.Names}}' 2>/dev/null || true
}

find_container_regex() {
  local pattern="$1"
  docker_container_names | grep -Ei "$pattern" | head -n 1 || true
}

check_container_regex() {
  local label="$1" pattern="$2"
  if [[ -n "$(find_container_regex "$pattern")" ]]; then
    ok "$label container is running"
    return 0
  fi
  warn "$label container was not found"
  return 1
}

run_docker_exec() {
  local container="$1"
  shift
  if docker exec "$container" "$@" 2>/dev/null; then
    return 0
  fi
  if have sudo; then
    sudo docker exec "$container" "$@" 2>/dev/null
    return $?
  fi
  return 1
}

verify_postgres_extensions_best_effort() {
  local container output failures=0
  container="$(find_container_regex 'supabase.*(db|postgres)|postgres')"
  if [[ -z "$container" ]]; then
    warn "Skipping PostgreSQL extension check because no PostgreSQL container was found"
    return 1
  fi

  output="$(
    run_docker_exec "$container" sh -lc \
      "psql -U postgres -d postgres -tAc \"select extname from pg_extension where extname in ('postgis','uuid-ossp','pg_trgm') order by extname;\"" \
      2>/dev/null || true
  )"
  if [[ -z "$output" ]]; then
    warn "Could not query PostgreSQL extensions inside $container"
    return 1
  fi

  for ext in postgis uuid-ossp pg_trgm; do
    if grep -Eq "(^|[[:space:]])${ext}($|[[:space:]])" <<<"$output"; then
      ok "PostgreSQL extension enabled: $ext"
    else
      warn "PostgreSQL extension missing: $ext"
      failures=1
    fi
  done
  return "$failures"
}

verify_foundation_services() {
  local failures=0
  if ! have docker; then
    warn "Docker is not installed; skipping Coolify/Supabase/Redis container checks"
    return 1
  fi
  if ! start_docker_if_possible; then
    warn "Docker is not running; skipping Coolify/Supabase/Redis container checks"
    return 1
  fi

  check_container_regex "Coolify" 'coolify' || failures=1
  check_container_regex "Supabase PostgreSQL" 'supabase.*(db|postgres)|postgres' || failures=1
  check_container_regex "Supabase Realtime" 'supabase.*realtime|realtime' || failures=1
  check_container_regex "Supabase Storage" 'supabase.*storage|storage' || failures=1
  check_container_regex "Supabase Studio" 'supabase.*studio|studio' || failures=1
  check_container_regex "Redis" 'redis' || failures=1
  verify_postgres_extensions_best_effort || failures=1

  if [[ "$failures" == "0" ]]; then
    ok "Coolify/Supabase/Redis foundation checks passed"
  else
    warn "Some foundation checks failed. This is expected until Supabase and Redis are deployed in Coolify."
  fi
  return "$failures"
}

verify_tailscale_active() {
  if ! have tailscale; then
    warn "Tailscale is not installed"
    return 1
  fi
  local ts_ip
  ts_ip="$(tailscale_ip)"
  if [[ -n "$ts_ip" ]]; then
    ok "Tailscale IP is active: $ts_ip"
    return 0
  fi
  warn "Tailscale is installed but no IPv4 address is active"
  return 1
}

verify_all() {
  source_config
  source_tunnel_env_if_present
  local method="${TUNNEL_METHOD:-cloudflare}"

  if [[ "$method" == "tailscale" ]]; then
    verify_tailscale_active || true
    check_local_ports
    verify_foundation_services || true
    ok ".env.tunnel API_URL=${API_URL:-http://${TAILSCALE_IP:-127.0.0.1}:$CF_API_PORT}"
    return 0
  fi

  if [[ "$method" == "direct-ip" ]]; then
    check_local_ports
    verify_foundation_services || true
    ok ".env.tunnel API_URL=${API_URL:-http://${PUBLIC_IP:-127.0.0.1}:$CF_API_PORT}"
    return 0
  fi

  ensure_core_deps
  local tunnel_id="${TUNNEL_ID:-}"
  [[ -n "$tunnel_id" ]] || tunnel_id="$(find_tunnel_id)"
  [[ -n "$tunnel_id" ]] || die "No tunnel found. Run './setup-cloudflare-tunnel.sh setup' first."
  local target="$tunnel_id.cfargotunnel.com"
  local zone_id response status

  zone_id="$(resolve_zone_id)"
  verify_dns_record "$zone_id" "$API_HOSTNAME" "$target"
  verify_dns_record "$zone_id" "$ADMIN_HOSTNAME" "$target"
  verify_dns_record "$zone_id" "$STUDIO_HOSTNAME" "$target"

  response="$(cf_api GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$tunnel_id")"
  status="$(jq -r '.result.status // "unknown"' <<<"$response")"
  if [[ "$status" == "healthy" ]]; then
    ok "Tunnel status is healthy"
  else
    warn "Tunnel status is $status. This is normal before cloudflared is running."
  fi

  check_local_ports
  if [[ "$CF_ROUTE_MODE" == "coolify-proxy" ]]; then
    coolify_status
  fi
  verify_foundation_services || true
  ok ".env.tunnel API_URL=${API_URL:-https://$API_HOSTNAME}"
}

doctor() {
  source_config
  source_tunnel_env_if_present
  printf 'Config file:       %s\n' "$CONFIG_FILE"
  printf 'Secrets file:      %s\n' "$SECRETS_FILE"
  printf 'Tunnel env file:   %s\n' "$ENV_FILE"
  printf 'Domain:            %s\n' "$CF_DOMAIN_NORMALIZED"
  printf 'Tunnel name:       %s\n' "$CF_TUNNEL_NAME"
  printf 'Route mode:        %s\n' "$CF_ROUTE_MODE"
  printf 'Origin host:       %s\n' "$CF_ORIGIN_HOST"
  printf 'API origin:        %s\n' "$(service_url_for api)"
  printf 'Admin origin:      %s\n' "$(service_url_for admin)"
  printf 'Studio origin:     %s\n' "$(service_url_for studio)"
  printf 'Coolify dashboard: %s\n' "$(coolify_dashboard_url "$(detect_wsl_ip)")"
  printf 'API URL:           %s\n' "$API_URL"
  printf 'Admin URL:         %s\n' "$ADMIN_PANEL_URL"
  printf 'Studio URL:        %s\n' "$SUPABASE_STUDIO_URL"
  printf 'WSL detected:      %s\n' "$(is_wsl && printf yes || printf no)"
  printf 'curl:              %s\n' "$(have curl && curl --version | head -n 1 || printf missing)"
  printf 'jq:                %s\n' "$(have jq && jq --version || printf missing)"
  printf 'openssl:           %s\n' "$(have openssl && openssl version || printf missing)"
  printf 'cloudflared:       %s\n' "$(have cloudflared && cloudflared --version 2>/dev/null || printf missing)"
  printf 'tailscale:         %s\n' "$(have tailscale && tailscale version 2>/dev/null | head -n 1 || printf missing)"

  if have curl && have jq && have openssl; then
    check_cloudflare_token_nonfatal || true
  else
    warn "Install missing core dependencies before API diagnostics."
  fi
}

print_env() {
  source_config
  source_tunnel_env_if_present
  if [[ -f "$ENV_FILE" ]]; then
    printf 'TUNNEL_METHOD=%s\n' "${TUNNEL_METHOD:-cloudflare}"
    printf 'API_URL=%s\n' "${API_URL:-https://$API_HOSTNAME}"
    printf 'API_BASE_URL=%s\n' "${API_BASE_URL:-${API_URL:-https://$API_HOSTNAME}}"
    printf 'FLUTTER_API_URL=%s\n' "${FLUTTER_API_URL:-${API_URL:-https://$API_HOSTNAME}}"
    printf 'ADMIN_PANEL_URL=%s\n' "${ADMIN_PANEL_URL:-https://$ADMIN_HOSTNAME}"
    printf 'SUPABASE_STUDIO_URL=%s\n' "${SUPABASE_STUDIO_URL:-https://$STUDIO_HOSTNAME}"
    printf 'COOLIFY_DASHBOARD_URL=%s\n' "${COOLIFY_DASHBOARD_URL:-$(coolify_dashboard_url "$(detect_wsl_ip)")}"
    printf 'TAILSCALE_IP=%s\n' "${TAILSCALE_IP:-}"
    printf 'PUBLIC_IP=%s\n' "${PUBLIC_IP:-}"
  else
    warn "$ENV_FILE does not exist yet. Run setup first."
    printf 'API_URL=%s\n' "$API_URL"
  fi
}

main() {
  local command="${1:-setup}"
  case "$command" in
    all) setup_all ;;
    install-coolify) install_coolify ;;
    configure-secrets) configure_secrets ;;
    setup) setup_tunnel ;;
    tunnel) interactive_tunnel ;;
    run) run_tunnel ;;
    service-install) service_install ;;
    install-cloudflared) source_config; install_cloudflared ;;
    tailscale) tailscale_setup ;;
    verify) verify_all ;;
    coolify-status) coolify_status ;;
    wsl-ip) print_wsl_ip ;;
    direct-ip) direct_ip_info ;;
    coolify-guide) coolify_guide ;;
    doctor) doctor ;;
    print-env) print_env ;;
    help|-h|--help) usage ;;
    *) usage; die "Unknown command: $command" ;;
  esac
}

main "$@"
