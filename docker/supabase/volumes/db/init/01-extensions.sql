-- =============================================================================
-- 01-extensions.sql
-- PostgreSQL extensions and initial setup for Colony.
-- This runs automatically when the Supabase container first starts.
-- =============================================================================

-- ── Core UUID generation ───────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ── PostGIS: geospatial queries (distance, radius search, location data) ───────
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "postgis_topology";

-- ── Fuzzy text search (search by partial name, typo-tolerant) ─────────────────
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ── Unaccented text search (handles international characters) ──────────────────
CREATE EXTENSION IF NOT EXISTS "unaccent";

-- ── Full text search configuration ────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "fuzzystrmatch";

-- ── Cryptographic functions (for tokens, hashing) ─────────────────────────────
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── HTTP client for webhook calls from database triggers ──────────────────────
-- CREATE EXTENSION IF NOT EXISTS "http";  -- Uncomment if needed

-- ── Verify all extensions installed ───────────────────────────────────────────
DO $$
DECLARE
    ext_name TEXT;
    ext_list TEXT[] := ARRAY[
        'uuid-ossp', 'postgis', 'pg_trgm', 'unaccent', 'fuzzystrmatch', 'pgcrypto'
    ];
BEGIN
    FOREACH ext_name IN ARRAY ext_list LOOP
        IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = ext_name) THEN
            RAISE NOTICE 'Extension % installed OK', ext_name;
        ELSE
            RAISE WARNING 'Extension % NOT installed', ext_name;
        END IF;
    END LOOP;
END $$;
