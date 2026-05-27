# Colony Backend

Backend infrastructure for Colony — WSL-based development environment with Coolify, Supabase self-hosted, and permanent Cloudflare Tunnel.

**Live domain:** `ilovespdf.in`

---

## Permanent Public URLs

| Service | URL |
|---------|-----|
| API | https://api.ilovespdf.in |
| Admin Panel | https://admin.ilovespdf.in |
| Supabase Studio | https://studio.ilovespdf.in |
| Coolify Dashboard | https://coolify.ilovespdf.in |

These URLs **never change** — they survive WSL restarts, NAT changes, IP changes, and router reboots.

---

## First-Time Setup (run once)

```bash
# In WSL — from the project root
bash backend/scripts/setup.sh              # Full environment: Docker + Coolify + Supabase
bash backend/scripts/cloudflare-setup.sh  # Permanent tunnel + DNS
```

---

## Every Dev Session

```bash
bash backend/scripts/find-wsl-ip.sh    # Print local URLs (WSL IP changes on restart)
bash backend/scripts/tunnel.sh start   # Start Cloudflare tunnel
bash backend/scripts/verify.sh         # Health check all services
```

---

## Script Reference

| Script | When to run | What it does |
|--------|-------------|--------------|
| `scripts/setup.sh` | Once | Full env: Docker → Coolify → Supabase |
| `scripts/cloudflare-setup.sh` | Once | Tunnel + DNS via Cloudflare API |
| `scripts/tunnel.sh start/stop` | Every session | Manage tunnel daemon |
| `scripts/tunnel-status.sh` | Any time | Visual health check with HTTP tests |
| `scripts/find-wsl-ip.sh` | After WSL restart | Refresh local URLs |
| `scripts/tailscale-setup.sh` | Once (optional) | Stable IP for device testing |
| `scripts/verify.sh` | Any time | Full pass/fail health check |
| `push-backend.sh` | After commits | Sync to colony_backend repo |

---

## Stack

- **WSL2** Ubuntu — Linux environment on Windows
- **Docker Engine** — Container runtime (not Docker Desktop)
- **Coolify** — Self-hosted PaaS on port 8000
- **Supabase self-hosted** — All services via Docker Compose:
  - PostgreSQL 15 with PostGIS, uuid-ossp, pg_trgm, pgcrypto
  - Supabase Studio (visual DB UI)
  - PostgREST (auto REST API)
  - GoTrue (Auth)
  - Realtime (WebSocket broadcasts)
  - Storage (file uploads)
  - Kong (API Gateway)
  - Edge Functions
- **Cloudflare Tunnel** — Permanent public URLs, no port forwarding
- **Tailscale** — Stable IP for local device testing

---

## Repo Strategy

This `backend/` folder is a **git subtree** of [colony-app](https://github.com/devamskshinde/colony-app).

- `colony-app` contains **everything** (frontend + backend)
- `colony_backend` contains **backend only** (this folder)

To sync after committing:

```bash
bash push-backend.sh "your commit message"
```
