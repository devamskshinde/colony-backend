#!/bin/bash
# =============================================================================
# verify-schema.sh — Colony Phase 1.1 Schema Verification
#
# Connects to the colony-db PostgreSQL container and runs comprehensive checks
# against the expected schema state after running all Phase 1.1 migrations.
#
# Usage:
#   bash scripts/verify-schema.sh           # Check against running colony-db container
#   bash scripts/verify-schema.sh --host    # Check against host PostgreSQL (see config below)
#   bash scripts/verify-schema.sh --help    # Show this help
#
# Exit code: 0 = all checks passed, 1 = one or more failed
# =============================================================================

set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

PASS=0; FAIL=0; WARN=0

ok()    { echo -e "  ${GREEN}✓${RESET}  $*";       (( PASS++ )) || true; }
fail()  { echo -e "  ${RED}✗${RESET}  $*";         (( FAIL++ )) || true; }
warn()  { echo -e "  ${YELLOW}~${RESET}  $*";      (( WARN++ )) || true; }
info()  { echo -e "  ${CYAN}·${RESET}  $*"; }
sec()   { echo -e "\n${BOLD}${CYAN}── $* ${RESET}"; }

# ── Help ─────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo ""
    echo -e "${BOLD}${CYAN}Colony Schema Verifier${RESET}  — verify-schema.sh"
    echo ""
    echo "Verifies that Phase 1.1 database schema is correctly applied."
    echo "Checks: tables, extensions, indexes, seeds, FK relationships, PostGIS."
    echo ""
    echo -e "${BOLD}Usage:${RESET}"
    echo "  bash scripts/verify-schema.sh           Check via Docker (colony-db container)"
    echo "  bash scripts/verify-schema.sh --host    Check against host PostgreSQL directly"
    echo "  bash scripts/verify-schema.sh --help    Show this help"
    echo ""
    echo -e "${BOLD}Prerequisites:${RESET}"
    echo "  - colony-db Docker container must be running, OR"
    echo "  - PGHOST / PGPORT / PGUSER / PGPASSWORD env vars set for --host mode"
    echo ""
    exit 0
fi

# ── PostgreSQL executor ───────────────────────────────────────────────────────
MODE="${1:-}"

if [[ "$MODE" == "--host" ]]; then
    PGUSER="${PGUSER:-postgres}"
    PGPASSWORD="${PGPASSWORD:-postgres}"
    PGHOST="${PGHOST:-localhost}"
    PGPORT="${PGPORT:-5432}"
    PGDB="${PGDATABASE:-postgres}"
    sql() { PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -tAc "$1" 2>/dev/null || echo "ERROR"; }
    sql_noout() { PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDB" -c "$1" &>/dev/null 2>&1; }
else
    # Default: Docker container
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^colony-db$"; then
        echo -e "${RED}ERROR: colony-db container is not running.${RESET}"
        echo "Start it: bash scripts/colony.sh start"
        exit 1
    fi
    sql()      { docker exec colony-db psql -U postgres -tAc "$1" 2>/dev/null || echo "ERROR"; }
    sql_noout() { docker exec colony-db psql -U postgres -c "$1" &>/dev/null 2>&1; }
fi

# ── Table existence check ─────────────────────────────────────────────────────
table_exists() {
    local TABLE="$1"
    local RESULT
    RESULT="$(sql "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_name='${TABLE}';")"
    [[ "$RESULT" == "1" ]]
}

check_table() {
    local TABLE="$1"
    if table_exists "$TABLE"; then
        ok "Table: public.${TABLE}"
    else
        fail "Table MISSING: public.${TABLE}"
    fi
}

# ── Index existence check ─────────────────────────────────────────────────────
index_exists() {
    local IDX="$1"
    local RESULT
    RESULT="$(sql "SELECT COUNT(*) FROM pg_indexes WHERE schemaname='public' AND indexname='${IDX}';")"
    [[ "$RESULT" == "1" ]]
}

check_index() {
    local IDX="$1" DESC="$2"
    if index_exists "$IDX"; then
        ok "Index: ${IDX}"
    else
        fail "Index MISSING: ${IDX}  (${DESC})"
    fi
}

# ═════════════════════════════════════════════════════════════════════════════
# BEGIN CHECKS
# ═════════════════════════════════════════════════════════════════════════════

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║  Colony — Phase 1.1 Schema Verification              ║${RESET}"
echo -e "${BOLD}${CYAN}║  $(date)                     ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"

# ─────────────────────────────────────────────────────────────────────────────
sec "1. PostgreSQL Connection"
# ─────────────────────────────────────────────────────────────────────────────

PG_VERSION="$(sql "SELECT version();")"
if [[ "$PG_VERSION" != "ERROR" && -n "$PG_VERSION" ]]; then
    ok "PostgreSQL connected: $(echo "$PG_VERSION" | head -c 60)"
else
    fail "Cannot connect to PostgreSQL"
    echo -e "\n${RED}Cannot continue without database connection.${RESET}"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
sec "2. Required Extensions"
# ─────────────────────────────────────────────────────────────────────────────

check_extension() {
    local EXT="$1"
    local COUNT; COUNT="$(sql "SELECT COUNT(*) FROM pg_extension WHERE extname='${EXT}';")"
    if [[ "$COUNT" == "1" ]]; then
        local VER; VER="$(sql "SELECT extversion FROM pg_extension WHERE extname='${EXT}';")"
        ok "Extension: ${EXT} (v${VER})"
    else
        fail "Extension NOT installed: ${EXT}"
    fi
}

check_extension "uuid-ossp"
check_extension "postgis"
check_extension "pg_trgm"
check_extension "pgcrypto"

# PostGIS functionality test
POSTGIS_TEST="$(sql "SELECT ST_AsText(ST_GeomFromText('POINT(77.5946 12.9716)', 4326));" 2>/dev/null || echo "ERROR")"
if [[ "$POSTGIS_TEST" == *"POINT"* ]]; then
    ok "PostGIS spatial query works (Bangalore coordinates: POINT(77.5946 12.9716))"
else
    fail "PostGIS spatial query FAILED — extension may be broken"
fi

# ─────────────────────────────────────────────────────────────────────────────
sec "3. Core Tables — Users & Auth"
# ─────────────────────────────────────────────────────────────────────────────

check_table "_colony_migrations"
check_table "_colony_meta"
check_table "users"
check_table "user_devices"
check_table "user_sessions"

# Verify critical columns on users table
COLS="$(sql "SELECT column_name FROM information_schema.columns WHERE table_schema='public' AND table_name='users' ORDER BY column_name;" 2>/dev/null | tr '\n' ' ')"
REQUIRED_COLS=("id" "email" "mobile_number" "password_hash" "username" "full_name" "location" "geohash" "colony_score" "is_banned" "is_shadow_banned" "premium_tier" "deleted_at")
for COL in "${REQUIRED_COLS[@]}"; do
    if echo "$COLS" | grep -qw "$COL"; then
        ok "Column users.${COL} exists"
    else
        fail "Column MISSING: users.${COL}"
    fi
done

# Verify location column is PostGIS geometry type
LOC_TYPE="$(sql "SELECT udt_name FROM information_schema.columns WHERE table_schema='public' AND table_name='users' AND column_name='location';")"
if [[ "$LOC_TYPE" == "geometry" ]]; then
    ok "users.location is PostGIS geometry type"
else
    fail "users.location is NOT geometry type (got: ${LOC_TYPE:-missing})"
fi

# ─────────────────────────────────────────────────────────────────────────────
sec "4. Social Tables"
# ─────────────────────────────────────────────────────────────────────────────

check_table "waves"
check_table "connections"

# ─────────────────────────────────────────────────────────────────────────────
sec "5. Messaging Tables"
# ─────────────────────────────────────────────────────────────────────────────

check_table "conversations"
check_table "conversation_participants"
check_table "messages"
check_table "message_reactions"
check_table "message_reads"

# ─────────────────────────────────────────────────────────────────────────────
sec "6. Content Tables"
# ─────────────────────────────────────────────────────────────────────────────

check_table "posts"
check_table "post_media"
check_table "post_likes"
check_table "post_saves"
check_table "post_comments"
check_table "stories"
check_table "story_elements"
check_table "story_views"
check_table "reels"
check_table "reel_watch_events"

# ─────────────────────────────────────────────────────────────────────────────
sec "7. Discovery Tables"
# ─────────────────────────────────────────────────────────────────────────────

check_table "businesses"
check_table "business_hours"
check_table "business_interactions"
check_table "business_reviews"
check_table "polls"
check_table "poll_options"
check_table "poll_votes"
check_table "events"
check_table "event_rsvps"
check_table "marketplace_listings"
check_table "marketplace_images"

# ─────────────────────────────────────────────────────────────────────────────
sec "8. Moderation & Notification Tables"
# ─────────────────────────────────────────────────────────────────────────────

check_table "reports"
check_table "notifications"
check_table "location_history"

# ─────────────────────────────────────────────────────────────────────────────
sec "9. Admin Tables"
# ─────────────────────────────────────────────────────────────────────────────

check_table "admin_users"
check_table "admin_audit_log"
check_table "feature_flags"
check_table "app_config"
check_table "secrets"

# ─────────────────────────────────────────────────────────────────────────────
sec "10. Critical Indexes"
# ─────────────────────────────────────────────────────────────────────────────

# Geospatial indexes (most critical — standard indexes cannot do distance queries)
check_index "idx_users_location_geo"     "PostGIS GIST index for nearby user queries"
check_index "idx_posts_location_geo"     "PostGIS GIST index for nearby post queries"
check_index "idx_stories_location_geo"   "PostGIS GIST index for nearby story queries"
check_index "idx_businesses_location_geo" "PostGIS GIST index for nearby business queries"
check_index "idx_events_location_geo"    "PostGIS GIST index for nearby event queries"
check_index "idx_marketplace_location_geo" "PostGIS GIST index for nearby listing queries"
check_index "idx_location_history_geo"   "PostGIS GIST index for location history"

# Full-text search indexes
check_index "idx_users_name_trgm"        "GIN trigram index for user name search"
check_index "idx_users_username_trgm"    "GIN trigram index for username search"
check_index "idx_businesses_name_trgm"   "GIN trigram index for business name search"

# Core query indexes
check_index "idx_users_geohash"          "Geohash-based area grouping"
check_index "idx_users_last_active"      "Recently active users query"
check_index "idx_waves_receiver"         "Incoming waves for a user"
check_index "idx_messages_conv"          "Messages by conversation"
check_index "idx_posts_author"           "Posts by author"
check_index "idx_posts_created"          "Posts feed (chronological)"
check_index "idx_notifications_unread"   "Unread notification badge count"
check_index "idx_sessions_expires"       "Session cleanup job"
check_index "idx_feature_flags_key"      "Feature flag lookup by key"
check_index "idx_audit_log_admin"        "Audit trail by admin"

# ─────────────────────────────────────────────────────────────────────────────
sec "11. Triggers"
# ─────────────────────────────────────────────────────────────────────────────

check_trigger() {
    local TRG="$1" TBL="$2"
    local COUNT; COUNT="$(sql "SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_name='${TRG}' AND event_object_table='${TBL}';")"
    if [[ "$COUNT" -ge "1" ]]; then
        ok "Trigger: ${TRG} on ${TBL}"
    else
        fail "Trigger MISSING: ${TRG} on ${TBL}"
    fi
}

check_trigger "trg_audit_immutable_update" "admin_audit_log"
check_trigger "trg_audit_immutable_delete" "admin_audit_log"
check_trigger "trg_users_updated_at"       "users"
check_trigger "trg_posts_updated_at"       "posts"

# Test audit log immutability
if sql_noout "UPDATE public.admin_audit_log SET notes='test' WHERE FALSE;"; then
    fail "Audit log immutability trigger is NOT working (UPDATE should throw)"
else
    ok "Audit log is immutable (UPDATE blocked by trigger)"
fi

# ─────────────────────────────────────────────────────────────────────────────
sec "12. Seed Data Verification"
# ─────────────────────────────────────────────────────────────────────────────

# Feature flags
FLAG_COUNT="$(sql "SELECT COUNT(*) FROM public.feature_flags;")"
if [[ "$FLAG_COUNT" -ge "50" ]]; then
    ok "Feature flags seeded: ${FLAG_COUNT} flags"
else
    fail "Feature flags: only ${FLAG_COUNT} found — expected ≥ 50. Run: psql < seeds/001_feature_flags.sql"
fi

# Check specific critical flags
for FLAG in "waves" "direct_messaging" "posts" "stories" "reels" "businesses" "admin_panel"; do
    COUNT="$(sql "SELECT COUNT(*) FROM public.feature_flags WHERE flag_key='${FLAG}';")"
    if [[ "$COUNT" == "1" ]]; then
        ok "Flag '${FLAG}' exists"
    else
        fail "Flag '${FLAG}' MISSING"
    fi
done

# App config
CONFIG_COUNT="$(sql "SELECT COUNT(*) FROM public.app_config;")"
if [[ "$CONFIG_COUNT" -ge "40" ]]; then
    ok "App config seeded: ${CONFIG_COUNT} keys"
else
    fail "App config: only ${CONFIG_COUNT} found — expected ≥ 40. Run: psql < seeds/002_app_config.sql"
fi

# Check specific critical config keys
for KEY in "discovery.default_radius_km" "waves.expiry_hours" "security.session_access_ttl_minutes"; do
    COUNT="$(sql "SELECT COUNT(*) FROM public.app_config WHERE key='${KEY}';")"
    if [[ "$COUNT" == "1" ]]; then
        ok "Config key '${KEY}' exists"
    else
        fail "Config key '${KEY}' MISSING"
    fi
done

# Admin user
ADMIN_COUNT="$(sql "SELECT COUNT(*) FROM public.admin_users WHERE is_active = TRUE;")"
if [[ "$ADMIN_COUNT" -ge "1" ]]; then
    ADMIN_EMAIL="$(sql "SELECT email FROM public.admin_users WHERE role='super_admin' LIMIT 1;")"
    ok "Super admin exists: ${ADMIN_EMAIL} (${ADMIN_COUNT} active admins total)"
else
    fail "No active admin users found. Run: psql < seeds/003_admin_user.sql"
fi

# ─────────────────────────────────────────────────────────────────────────────
sec "13. Foreign Key Relationships"
# ─────────────────────────────────────────────────────────────────────────────

FK_COUNT="$(sql "SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_type='FOREIGN KEY' AND constraint_schema='public';")"
if [[ "$FK_COUNT" -ge "20" ]]; then
    ok "Foreign key constraints: ${FK_COUNT} defined"
else
    warn "Foreign key count low: ${FK_COUNT} (expected ≥ 20)"
fi

# Key FK relationships to validate
check_fk() {
    local TABLE="$1" FK_NAME="$2"
    local COUNT; COUNT="$(sql "SELECT COUNT(*) FROM information_schema.table_constraints WHERE constraint_type='FOREIGN KEY' AND table_name='${TABLE}' AND constraint_name='${FK_NAME}';")"
    if [[ "$COUNT" == "1" ]]; then
        ok "FK: ${TABLE}.${FK_NAME}"
    else
        warn "FK not found: ${TABLE}.${FK_NAME} (may have different name)"
    fi
}

check_fk "user_devices"              "user_devices_user_id_fkey"
check_fk "user_sessions"             "user_sessions_user_id_fkey"
check_fk "waves"                     "waves_sender_id_fkey"
check_fk "waves"                     "waves_receiver_id_fkey"
check_fk "connections"               "connections_user_a_id_fkey"
check_fk "messages"                  "messages_conversation_id_fkey"
check_fk "posts"                     "posts_author_id_fkey"
check_fk "admin_audit_log"           "admin_audit_log_admin_id_fkey"

# ─────────────────────────────────────────────────────────────────────────────
sec "14. Row Level Security"
# ─────────────────────────────────────────────────────────────────────────────

check_rls() {
    local TABLE="$1"
    local RESULT; RESULT="$(sql "SELECT rowsecurity FROM pg_tables WHERE schemaname='public' AND tablename='${TABLE}';")"
    if [[ "$RESULT" == "t" ]]; then
        ok "RLS enabled: ${TABLE}"
    else
        fail "RLS NOT enabled: ${TABLE}"
    fi
}

check_rls "users"
check_rls "messages"
check_rls "posts"
check_rls "notifications"
check_rls "feature_flags"

# ─────────────────────────────────────────────────────────────────────────────
sec "15. Migration Version"
# ─────────────────────────────────────────────────────────────────────────────

MIGRATION_VER="$(sql "SELECT version FROM public._colony_migrations ORDER BY applied_at DESC LIMIT 1;")"
if [[ "$MIGRATION_VER" == "001" ]]; then
    ok "Migration version: 001 (Phase 1.1 initial schema)"
else
    warn "Latest migration: ${MIGRATION_VER:-none recorded}"
fi

# ─────────────────────────────────────────────────────────────────────────────
sec "16. Quick Functional Tests"
# ─────────────────────────────────────────────────────────────────────────────

# Test INSERT and UNIQUE constraint on users
TEST_ID="00000000-0000-0000-0000-000000000001"
sql_noout "DELETE FROM public.users WHERE id='${TEST_ID}';" || true
INSERT_RESULT="$(sql "
INSERT INTO public.users (id, email, mobile_number, password_hash, username, full_name)
VALUES ('${TEST_ID}', 'verify-test@colony.test', '+9100000000001', '\$2b\$12\$test', 'verify_test_user', 'Verify Test User')
ON CONFLICT DO NOTHING
RETURNING id;" 2>/dev/null || echo "ERROR")"

if [[ "$INSERT_RESULT" == "$TEST_ID" ]] || [[ "$INSERT_RESULT" == "" ]]; then
    ok "User INSERT works (idempotent)"
else
    warn "User INSERT returned: ${INSERT_RESULT}"
fi

# Test geospatial INSERT
GEO_RESULT="$(sql "
UPDATE public.users
SET location = ST_GeomFromText('POINT(77.5946 12.9716)', 4326),
    geohash = 'tdr1y'
WHERE id = '${TEST_ID}'
RETURNING ST_AsText(location);" 2>/dev/null || echo "ERROR")"

if [[ "$GEO_RESULT" == *"POINT"* ]]; then
    ok "PostGIS location update works: ${GEO_RESULT}"
else
    fail "PostGIS location update FAILED: ${GEO_RESULT}"
fi

# Test nearby distance query (the core query type for Colony)
NEARBY_RESULT="$(sql "
SELECT COUNT(*) FROM public.users
WHERE ST_DWithin(
    location::geography,
    ST_GeomFromText('POINT(77.5946 12.9716)', 4326)::geography,
    5000
) AND deleted_at IS NULL;" 2>/dev/null || echo "ERROR")"

if [[ "$NEARBY_RESULT" != "ERROR" ]]; then
    ok "Nearby users query works (ST_DWithin geospatial, 5km radius): ${NEARBY_RESULT} results"
else
    fail "Nearby users geospatial query FAILED"
fi

# Clean up test data
sql_noout "DELETE FROM public.users WHERE id='${TEST_ID}';" || true

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${CYAN}║  Verification Summary                                ║${RESET}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${GREEN}✓ Passed:   ${PASS}${RESET}"
echo -e "  ${YELLOW}~ Warnings: ${WARN}${RESET}"
echo -e "  ${RED}✗ Failed:   ${FAIL}${RESET}"
echo ""

if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}✅ Phase 1.1 schema fully verified — all checks passed!${RESET}"
    echo -e "   You are ready to proceed to Phase 1.2."
elif [[ $FAIL -eq 0 ]]; then
    echo -e "${YELLOW}${BOLD}⚠ Phase 1.1 schema mostly verified — minor warnings above.${RESET}"
    echo -e "   Review warnings before proceeding to Phase 1.2."
else
    echo -e "${RED}${BOLD}❌ ${FAIL} check(s) failed — schema incomplete.${RESET}"
    echo ""
    echo -e "${BOLD}Common fixes:${RESET}"
    echo -e "  Schema not applied:  docker exec -i colony-db psql -U postgres < backend/database/migrations/001_schema.sql"
    echo -e "  Flags not seeded:    docker exec -i colony-db psql -U postgres < backend/database/seeds/001_feature_flags.sql"
    echo -e "  Config not seeded:   docker exec -i colony-db psql -U postgres < backend/database/seeds/002_app_config.sql"
    echo -e "  Admin not seeded:    docker exec -i colony-db psql -U postgres < backend/database/seeds/003_admin_user.sql"
    echo ""
    echo -e "  Or run all at once:"
    echo -e "  ${CYAN}bash scripts/colony-setup.sh --schema${RESET}  (coming in next update)"
fi

echo ""

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
