#!/bin/bash
# =============================================================================
# apply-schema.sh — Apply Colony Phase 1.1 migrations and seeds
#
# Runs all SQL files in the correct order against colony-db.
# Idempotent — safe to run multiple times.
#
# Usage:
#   bash scripts/apply-schema.sh           # Apply via Docker (colony-db container)
#   bash scripts/apply-schema.sh --host    # Apply via host PostgreSQL
#   bash scripts/apply-schema.sh --verify  # Apply then verify
#   bash scripts/apply-schema.sh --help    # Show this help
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
fatal()   { error "$*"; exit 1; }
banner()  {
    echo -e "\n${BOLD}${CYAN}╔══════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}${CYAN}║  $*${RESET}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════╝${RESET}\n"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"
MIGRATIONS_DIR="${BACKEND_DIR}/database/migrations"
SEEDS_DIR="${BACKEND_DIR}/database/seeds"

# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo ""
    echo -e "${BOLD}${CYAN}Colony Schema Applier${RESET}  — apply-schema.sh"
    echo ""
    echo "Applies all Phase 1.1 migrations and seeds in correct order."
    echo ""
    echo -e "${BOLD}Usage:${RESET}"
    echo "  bash scripts/apply-schema.sh           Apply via Docker (colony-db)"
    echo "  bash scripts/apply-schema.sh --host    Apply via host PostgreSQL"
    echo "  bash scripts/apply-schema.sh --verify  Apply then run verify-schema.sh"
    echo "  bash scripts/apply-schema.sh --help    Show this help"
    echo ""
    exit 0
fi

MODE="${1:-}"
VERIFY=false
[[ "$MODE" == "--verify" ]] && { VERIFY=true; MODE=""; }

# ── SQL executor ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "--host" ]]; then
    PGUSER="${PGUSER:-postgres}"
    PGPASSWORD="${PGPASSWORD:-postgres}"
    PGHOST="${PGHOST:-localhost}"
    PGPORT="${PGPORT:-5432}"
    PGDB="${PGDATABASE:-postgres}"
    run_sql() {
        local FILE="$1"
        PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -f "$FILE"
    }
else
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^colony-db$"; then
        fatal "colony-db container not running. Start it: bash scripts/colony.sh start"
    fi
    run_sql() {
        local FILE="$1"
        docker exec -i colony-db psql -U postgres < "$FILE"
    }
fi

# ── Apply a SQL file ──────────────────────────────────────────────────────────
apply_file() {
    local FILE="$1" LABEL="$2"
    if [[ ! -f "$FILE" ]]; then
        warn "File not found, skipping: ${FILE}"
        return 0
    fi
    info "Applying: ${LABEL}  (${FILE##*/})"
    if run_sql "$FILE"; then
        success "${LABEL} applied."
    else
        fatal "Failed to apply: ${FILE}"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════

banner "Colony — Phase 1.1 Schema Application"

echo -e "${BOLD}Migration files:${RESET} ${MIGRATIONS_DIR}"
echo -e "${BOLD}Seed files:${RESET}      ${SEEDS_DIR}"
echo ""

# ── Step 1: Migrations ────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}── Migrations ──────────────────────────────────${RESET}"
apply_file "${MIGRATIONS_DIR}/001_schema.sql"      "Phase 1.1 Schema (tables, indexes, triggers, RLS)"

# ── Step 2: Seeds ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}── Seeds ───────────────────────────────────────${RESET}"
apply_file "${SEEDS_DIR}/001_feature_flags.sql"    "Feature Flags"
apply_file "${SEEDS_DIR}/002_app_config.sql"       "App Configuration"
apply_file "${SEEDS_DIR}/003_admin_user.sql"       "Admin Users"

echo ""
success "All Phase 1.1 migrations and seeds applied!"
echo ""
echo -e "${YELLOW}⚠ IMPORTANT:${RESET} Change admin@colony.app password before using in production!"
echo ""

if $VERIFY; then
    echo -e "${BOLD}Running schema verification...${RESET}"
    echo ""
    bash "${SCRIPT_DIR}/verify-schema.sh" "$MODE"
else
    echo -e "${BOLD}To verify the schema, run:${RESET}"
    echo -e "  ${CYAN}bash scripts/verify-schema.sh${RESET}"
fi
