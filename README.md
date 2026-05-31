# Colony Backend Foundation

This backend folder contains one script for the local backend foundation:

```bash
cd backend
./setup-cloudflare-tunnel.sh all
```

The script can install/check Coolify in WSL, create or reuse a permanent Cloudflare Tunnel, write Cloudflare DNS records, emit `.env.tunnel`, update `.env.local` with the current WSL IP, and install a restart-safe cloudflared connector.

## Files

- `cloudflare.config.sh`: fill once with domain, tunnel name, account id, API token, subdomains, and local ports. This file is ignored by git.
- `cloudflare.config.example.sh`: safe template to commit.
- `.env.tunnel`: generated after setup. It contains permanent URLs and can be sourced by later scripts.
- `.env.local`: generated machine-local WSL/Coolify state. This is ignored because WSL IPs can change.
- `setup-cloudflare-tunnel.sh`: one script for Coolify install/status, tunnel setup, tunnel run, service install, verification, and diagnostics.

## Coolify And WSL Notes

Coolify runs in WSL and gives you the dashboard for Supabase, Redis, apps, logs, env vars, and container health. Cloudflare Tunnel is used for stable public HTTPS URLs because your Windows/WSL machine has no reliable public inbound IP.

Recommended mode:

- Cloudflare DNS: `api`, `admin`, `studio` CNAMEs point to the permanent tunnel id.
- Cloudflare Tunnel ingress: all three hostnames point to Coolify's local proxy at `http://127.0.0.1:80`.
- Coolify routes by hostname to the correct resource.

This avoids depending on your home IP, router forwarding, or changing WSL IPs. The Flutter API URL remains stable:

```bash
https://api.ilovespdf.in
```

If you choose direct-port mode later, set `CF_ROUTE_MODE="ports"` and update `CF_API_PORT`, `CF_ADMIN_PORT`, and `CF_STUDIO_PORT`.

## Main Commands

```bash
./setup-cloudflare-tunnel.sh all
./setup-cloudflare-tunnel.sh install-coolify
./setup-cloudflare-tunnel.sh setup
./setup-cloudflare-tunnel.sh service-install
./setup-cloudflare-tunnel.sh verify
./setup-cloudflare-tunnel.sh doctor
./setup-cloudflare-tunnel.sh coolify-status
./setup-cloudflare-tunnel.sh wsl-ip
```

For a foreground tunnel test:

```bash
./setup-cloudflare-tunnel.sh run
```

For direct public IP diagnostics:

```bash
./setup-cloudflare-tunnel.sh direct-ip
```

Direct IP is only a fallback. If your ISP uses CGNAT or your IP changes, direct IP will break. Cloudflare Tunnel is the stable path.

## Coolify Setup

Open the dashboard printed by:

```bash
./setup-cloudflare-tunnel.sh coolify-status
```

Then:

1. Create the first Coolify admin immediately.
2. Add Supabase from New Resource -> Service -> Supabase.
3. Add Redis from New Resource -> Database -> Redis.
4. Configure Coolify resource domains to match the tunnel URLs:
   - `https://api.ilovespdf.in`
   - `https://admin.ilovespdf.in`
   - `https://studio.ilovespdf.in`

Manual verification after successful setup:

1. Open Cloudflare dashboard.
2. Select `ilovespdf.in`.
3. Go to DNS.
4. Confirm these CNAME records point to `<tunnel-id>.cfargotunnel.com`: `api`, `admin`, and `studio`.

## Reading The API URL Later

Any later setup script should do this instead of asking for the URL again:

```bash
set -a
. ./backend/.env.tunnel
set +a
echo "$API_URL"
```

Flutter build wrapper example:

```bash
set -a
. ./backend/.env.tunnel
set +a
flutter build apk --dart-define=API_BASE_URL="$API_URL"
```

## Troubleshooting

```bash
./setup-cloudflare-tunnel.sh doctor
./setup-cloudflare-tunnel.sh verify
```

If local services are not running yet, setup still succeeds by default. Set `CF_REQUIRE_LOCAL_PORTS="1"` in `cloudflare.config.sh` when you want closed local ports to fail the setup.

Do not push `cloudflare.config.sh` to GitHub. The API token in that file can change DNS and tunnel resources in your Cloudflare account.
