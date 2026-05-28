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

## Scripts — Just Two

The entire backend lifecycle is managed by **two intelligent scripts**:

| Script | Purpose |
|--------|---------|
| `colony-setup.sh` | **Installer** — Fresh setup, Cloudflare wiring, Tailscale |
| `colony.sh` | **Daily manager** — Start session, health check, git sync |

---

## First-Time Setup (run once)

```bash
# In WSL — from the project root
bash backend/scripts/colony-setup.sh              # Install Docker + Coolify + Supabase (idempotent)
bash backend/scripts/colony-setup.sh --cloudflare # Wire permanent Cloudflare tunnel + DNS
bash backend/scripts/colony-setup.sh --tailscale  # (Optional) stable IP for device testing
```

Each step is **idempotent** — rerunning skips already-completed work.

---

## Every Dev Session (after WSL restart)

```bash
bash backend/scripts/colony.sh start   # Detects IP changes, starts Docker/Supabase, prompts tunnel choice
bash backend/scripts/colony.sh status  # Full visual health check (pass/warn/fail per service)
```

### `colony.sh start` — Interactive Tunnel Selection

When you run `start` without a flag, you get a menu:

```
╔══════════════════════════════════════════════╗
║   Choose Your Connection Method              ║
╠══════════════════════════════════════════════╣
║  [1] Cloudflare Tunnel (Recommended)         ║
║  [2] Direct Public IP                        ║
║  [3] Tailscale                               ║
╚══════════════════════════════════════════════╝
```

Or skip the prompt with a flag:

```bash
bash backend/scripts/colony.sh start --cloudflare  # Cloudflare tunnel
bash backend/scripts/colony.sh start --direct      # Direct IP
bash backend/scripts/colony.sh start --tailscale   # Tailscale
```

---

## Full Command Reference

### `colony-setup.sh` — Installer

```bash
bash backend/scripts/colony-setup.sh              # Full fresh setup
bash backend/scripts/colony-setup.sh --cloudflare # Wire Cloudflare tunnel (run once)
bash backend/scripts/colony-setup.sh --tailscale  # Install & connect Tailscale
bash backend/scripts/colony-setup.sh --check      # Check prerequisites only (no installs)
```

### `colony.sh` — Session Manager

```bash
bash backend/scripts/colony.sh start              # Start session (interactive)
bash backend/scripts/colony.sh start --cloudflare # Start Cloudflare tunnel
bash backend/scripts/colony.sh start --direct     # Direct IP mode
bash backend/scripts/colony.sh start --tailscale  # Tailscale mode
bash backend/scripts/colony.sh stop               # Stop tunnel daemon
bash backend/scripts/colony.sh restart            # Stop + start
bash backend/scripts/colony.sh status             # Full health check
bash backend/scripts/colony.sh logs               # Tail Cloudflare tunnel logs
bash backend/scripts/colony.sh ip                 # Print WSL/public/Tailscale IPs
bash backend/scripts/colony.sh sync "message"     # Commit + push to both repos
```

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
- **Cloudflare Tunnel** — Permanent public URLs, no port forwarding required
- **Tailscale** — Stable 100.x IP for local device testing

---

## Repo Strategy

This `backend/` folder is a **git subtree** of [colony-app](https://github.com/devamskshinde/colony-app).

- `colony-app` — everything (frontend + backend)
- `colony-backend` — backend only (this folder)

To sync after committing:

```bash
bash backend/scripts/colony.sh sync "your commit message"
```

---

## Generated Environment Files

| File | Contents | When created |
|------|----------|-------------|
| `backend/.env.local` | WSL IP, local service URLs | Every `colony.sh start` |
| `backend/.env.tunnel` | Permanent public URLs | `colony-setup.sh --cloudflare` |
| `~/.cloudflared/config.yml` | cloudflared tunnel config | `colony-setup.sh --cloudflare` |
