-- =============================================================================
-- 001_schema.sql — Colony Full Database Schema (Phase 1.1)
-- Run this ONCE on a fresh Supabase/PostgreSQL instance.
-- Idempotent: uses CREATE TABLE IF NOT EXISTS throughout.
--
-- To apply:
--   docker exec -i colony-db psql -U postgres < backend/database/migrations/001_schema.sql
--   OR via Supabase Studio SQL editor.
-- =============================================================================

-- ── Extensions ────────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "postgis";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Schema version tracking ───────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public._colony_migrations (
    version      TEXT        PRIMARY KEY,
    description  TEXT        NOT NULL,
    applied_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 1: USERS & AUTH
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.users (
    -- Identity
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    email               TEXT        UNIQUE NOT NULL,
    mobile_number       TEXT        UNIQUE NOT NULL,
    password_hash       TEXT        NOT NULL,           -- bcrypt, never plain text
    username            TEXT        UNIQUE NOT NULL,
    full_name           TEXT        NOT NULL,
    bio                 TEXT,
    profile_photo_url   TEXT,
    cover_photo_url     TEXT,

    -- App-specific social data
    vibe_tags           TEXT[]      NOT NULL DEFAULT '{}',   -- interest labels user picks
    colony_score        INTEGER     NOT NULL DEFAULT 0 CHECK (colony_score >= 0),
    level_title         TEXT        NOT NULL DEFAULT 'Newcomer',
    mood_status         TEXT,                               -- short message visible to nearby users

    -- Location (PostGIS point — SRID 4326 = WGS84)
    location            GEOMETRY(POINT, 4326),
    geohash             TEXT,                               -- short string area identifier
    last_known_city     TEXT,
    last_known_area     TEXT,
    location_updated_at TIMESTAMPTZ,

    -- Account status
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    is_banned           BOOLEAN     NOT NULL DEFAULT FALSE,
    ban_reason          TEXT,
    ban_expires_at      TIMESTAMPTZ,                        -- NULL = permanent ban
    is_shadow_banned    BOOLEAN     NOT NULL DEFAULT FALSE,  -- user can't see they're banned
    is_content_restricted BOOLEAN   NOT NULL DEFAULT FALSE,  -- can't post/wave
    is_view_restricted  BOOLEAN     NOT NULL DEFAULT FALSE,  -- appears less in discovery
    restriction_reason  TEXT,

    -- Premium subscription
    is_premium          BOOLEAN     NOT NULL DEFAULT FALSE,
    premium_tier        TEXT        CHECK (premium_tier IN ('basic', 'pro', 'elite')),
    premium_expires_at  TIMESTAMPTZ,

    -- Device security flags
    is_rooted_device    BOOLEAN     NOT NULL DEFAULT FALSE,
    is_emulator         BOOLEAN     NOT NULL DEFAULT FALSE,
    trust_score         INTEGER     NOT NULL DEFAULT 100 CHECK (trust_score BETWEEN 0 AND 100),

    -- Admin-only internal metadata (never exposed to user)
    admin_notes         TEXT,
    risk_score          INTEGER     NOT NULL DEFAULT 0 CHECK (risk_score >= 0),
    internal_tags       TEXT[]      NOT NULL DEFAULT '{}',

    -- Onboarding
    is_onboarded        BOOLEAN     NOT NULL DEFAULT FALSE,
    onboarded_at        TIMESTAMPTZ,

    -- Email / mobile verification
    email_verified      BOOLEAN     NOT NULL DEFAULT FALSE,
    email_verified_at   TIMESTAMPTZ,
    mobile_verified     BOOLEAN     NOT NULL DEFAULT FALSE,
    mobile_verified_at  TIMESTAMPTZ,

    -- Counts (denormalized for query performance)
    wave_sent_count     INTEGER     NOT NULL DEFAULT 0,
    wave_received_count INTEGER     NOT NULL DEFAULT 0,
    connection_count    INTEGER     NOT NULL DEFAULT 0,
    post_count          INTEGER     NOT NULL DEFAULT 0,

    -- Timestamps
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_active_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ                         -- soft delete, NULL = active
);

COMMENT ON TABLE  public.users IS 'Core user accounts for the Colony app.';
COMMENT ON COLUMN public.users.password_hash IS 'bcrypt hash. Plain text never stored.';
COMMENT ON COLUMN public.users.geohash IS 'Geohash of location for proximity grouping.';
COMMENT ON COLUMN public.users.is_shadow_banned IS 'User sees normal UI but is invisible to others.';
COMMENT ON COLUMN public.users.trust_score IS '0-100. Affects algorithm ranking. Not shown to user.';

-- ── User Devices ──────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_devices (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

    device_id           TEXT        NOT NULL,              -- unique hardware identifier
    device_type         TEXT        NOT NULL CHECK (device_type IN ('android', 'ios', 'web')),
    device_model        TEXT,                              -- e.g. "Pixel 7", "iPhone 15"
    os_version          TEXT,                              -- e.g. "Android 14", "iOS 17.1"
    app_version         TEXT        NOT NULL,              -- e.g. "1.2.3"
    push_token          TEXT,                              -- FCM or APNS token
    push_token_updated_at TIMESTAMPTZ,

    -- Security
    is_rooted           BOOLEAN     NOT NULL DEFAULT FALSE,
    is_emulator         BOOLEAN     NOT NULL DEFAULT FALSE,
    device_fingerprint  TEXT,                              -- hash of device attributes

    is_active           BOOLEAN     NOT NULL DEFAULT TRUE, -- FALSE = logged out
    last_seen_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    UNIQUE (user_id, device_id)
);

COMMENT ON TABLE public.user_devices IS 'Registered devices per user account.';

-- ── User Sessions ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.user_sessions (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    device_id           UUID        REFERENCES public.user_devices(id) ON DELETE SET NULL,

    -- Token pair
    access_token_hash   TEXT        NOT NULL UNIQUE,       -- hash of JWT / opaque token
    refresh_token_hash  TEXT        NOT NULL UNIQUE,
    token_family        UUID        NOT NULL DEFAULT gen_random_uuid(),  -- for family-based invalidation

    -- Expiry
    access_expires_at   TIMESTAMPTZ NOT NULL,
    refresh_expires_at  TIMESTAMPTZ NOT NULL,

    -- Status
    is_valid            BOOLEAN     NOT NULL DEFAULT TRUE,
    invalidated_at      TIMESTAMPTZ,
    invalidation_reason TEXT        CHECK (invalidation_reason IN (
                            'logout', 'token_theft', 'admin_revoke', 'password_change',
                            'expired', 'device_removed'
                        )),

    -- Request metadata
    ip_address          INET,
    user_agent          TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  public.user_sessions IS 'Login sessions. Token family enables theft detection.';
COMMENT ON COLUMN public.user_sessions.token_family IS 'All tokens in a family get invalidated on reuse detection.';

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 2: SOCIAL — WAVES & CONNECTIONS
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.waves (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id           UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    receiver_id         UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

    wave_type           TEXT        NOT NULL DEFAULT 'standard'
                            CHECK (wave_type IN ('standard', 'super', 'anonymous')),
    status              TEXT        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'accepted', 'declined', 'expired', 'withdrawn')),
    message             TEXT,                              -- optional short message with the wave

    -- Lifecycle timestamps
    sent_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    responded_at        TIMESTAMPTZ,
    expires_at          TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '48 hours'),

    CONSTRAINT no_self_wave CHECK (sender_id <> receiver_id),
    CONSTRAINT unique_pending_wave UNIQUE (sender_id, receiver_id)  -- one active wave per pair
);

COMMENT ON TABLE public.waves IS 'Interest expressions between users. Mutual acceptance creates a connection.';

CREATE TABLE IF NOT EXISTS public.connections (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_a_id           UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    user_b_id           UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    wave_id             UUID        REFERENCES public.waves(id) ON DELETE SET NULL,

    -- Status
    status              TEXT        NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active', 'blocked', 'removed')),
    blocked_by          UUID        REFERENCES public.users(id),
    blocked_at          TIMESTAMPTZ,

    -- Closeness score for feed ranking
    affinity_score      REAL        NOT NULL DEFAULT 1.0,
    connected_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_interaction_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    CONSTRAINT ordered_connection CHECK (user_a_id < user_b_id),  -- prevent duplicate pairs
    UNIQUE (user_a_id, user_b_id)
);

COMMENT ON TABLE public.connections IS 'Confirmed mutual connection after both users wave each other.';

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 3: MESSAGING
-- ─────────────────────────────────────────────────────────────────────────────

-- Three conversation types share a messages table via polymorphism
CREATE TABLE IF NOT EXISTS public.conversations (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_type   TEXT        NOT NULL CHECK (conversation_type IN ('direct', 'area_group', 'user_group')),

    -- Direct (1-1) fields
    participant_a_id    UUID        REFERENCES public.users(id) ON DELETE CASCADE,
    participant_b_id    UUID        REFERENCES public.users(id) ON DELETE CASCADE,
    connection_id       UUID        REFERENCES public.connections(id) ON DELETE SET NULL,

    -- Area group fields
    area_zone_id        TEXT,                              -- geohash zone identifier
    area_name           TEXT,                              -- human-readable area name

    -- User group fields
    group_name          TEXT,
    group_photo_url     TEXT,
    group_description   TEXT,
    creator_id          UUID        REFERENCES public.users(id) ON DELETE SET NULL,
    invite_link_token   TEXT        UNIQUE,
    is_public           BOOLEAN     NOT NULL DEFAULT FALSE,

    -- Shared settings
    disappearing_messages_ttl INTEGER,                     -- seconds, NULL = off
    member_count        INTEGER     NOT NULL DEFAULT 0,
    last_message_at     TIMESTAMPTZ,
    last_message_preview TEXT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Ensure direct conversations have both participants
    CONSTRAINT direct_needs_participants CHECK (
        conversation_type <> 'direct' OR (participant_a_id IS NOT NULL AND participant_b_id IS NOT NULL)
    ),
    CONSTRAINT direct_ordered CHECK (
        conversation_type <> 'direct' OR participant_a_id < participant_b_id
    )
);

COMMENT ON TABLE public.conversations IS 'All conversation types: direct (1-1), area auto-group, user-created group.';

CREATE TABLE IF NOT EXISTS public.conversation_participants (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id         UUID        NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
    user_id                 UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

    role                    TEXT        NOT NULL DEFAULT 'member'
                                CHECK (role IN ('member', 'admin', 'owner')),
    nickname                TEXT,                          -- user's nickname in this group

    -- Per-participant state
    is_muted                BOOLEAN     NOT NULL DEFAULT FALSE,
    is_archived             BOOLEAN     NOT NULL DEFAULT FALSE,
    is_pinned               BOOLEAN     NOT NULL DEFAULT FALSE,
    has_blocked_conversation BOOLEAN    NOT NULL DEFAULT FALSE,
    unread_count            INTEGER     NOT NULL DEFAULT 0,

    last_read_at            TIMESTAMPTZ,
    joined_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    left_at                 TIMESTAMPTZ,                   -- NULL = still in conversation

    UNIQUE (conversation_id, user_id)
);

COMMENT ON TABLE public.conversation_participants IS 'Links users to conversations with per-user state.';

CREATE TABLE IF NOT EXISTS public.messages (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id     UUID        NOT NULL REFERENCES public.conversations(id) ON DELETE CASCADE,
    sender_id           UUID        NOT NULL REFERENCES public.users(id) ON DELETE SET NULL,

    -- Content
    message_type        TEXT        NOT NULL DEFAULT 'text'
                            CHECK (message_type IN (
                                'text', 'image', 'video', 'audio', 'file',
                                'location', 'contact', 'sticker', 'gif',
                                'poll', 'event_share', 'system'
                            )),
    content             TEXT,                              -- text content or caption
    media_url           TEXT,                              -- storage reference for media
    media_thumbnail_url TEXT,
    media_size_bytes    BIGINT,
    media_duration_sec  INTEGER,                           -- for audio/video
    media_width         INTEGER,
    media_height        INTEGER,

    -- Threading
    reply_to_id         UUID        REFERENCES public.messages(id) ON DELETE SET NULL,
    forwarded_from_id   UUID        REFERENCES public.messages(id) ON DELETE SET NULL,

    -- Lifecycle
    is_edited           BOOLEAN     NOT NULL DEFAULT FALSE,
    edited_at           TIMESTAMPTZ,
    is_deleted          BOOLEAN     NOT NULL DEFAULT FALSE,  -- soft delete, content replaced
    deleted_at          TIMESTAMPTZ,
    deleted_by          UUID        REFERENCES public.users(id),
    expires_at          TIMESTAMPTZ,                        -- for disappearing messages

    sent_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.messages IS 'All messages across all conversation types.';

CREATE TABLE IF NOT EXISTS public.message_reactions (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id          UUID        NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
    user_id             UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    emoji               TEXT        NOT NULL,
    reacted_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (message_id, user_id, emoji)
);

CREATE TABLE IF NOT EXISTS public.message_reads (
    message_id          UUID        NOT NULL REFERENCES public.messages(id) ON DELETE CASCADE,
    user_id             UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    read_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (message_id, user_id)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 4: CONTENT — POSTS, STORIES, REELS
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.posts (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    author_id           UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

    -- Content
    content_type        TEXT        NOT NULL DEFAULT 'text'
                            CHECK (content_type IN ('text', 'photo', 'video', 'mixed')),
    text_content        TEXT,
    content_warning     TEXT,                              -- e.g. "Sensitive: violence"

    -- Audience
    visibility          TEXT        NOT NULL DEFAULT 'area'
                            CHECK (visibility IN ('public', 'area', 'connections', 'private')),
    audience_radius_km  REAL,                              -- for 'area' visibility

    -- Location at time of post
    location            GEOMETRY(POINT, 4326),
    geohash             TEXT,
    location_name       TEXT,

    -- Engagement counts (denormalized)
    like_count          INTEGER     NOT NULL DEFAULT 0,
    comment_count       INTEGER     NOT NULL DEFAULT 0,
    share_count         INTEGER     NOT NULL DEFAULT 0,
    view_count          INTEGER     NOT NULL DEFAULT 0,
    save_count          INTEGER     NOT NULL DEFAULT 0,

    -- Admin controls
    is_boosted          BOOLEAN     NOT NULL DEFAULT FALSE,  -- admin shows this more
    boost_expires_at    TIMESTAMPTZ,
    is_suppressed       BOOLEAN     NOT NULL DEFAULT FALSE,  -- admin shows this less
    suppression_reason  TEXT,
    is_reported         BOOLEAN     NOT NULL DEFAULT FALSE,
    report_count        INTEGER     NOT NULL DEFAULT 0,

    -- Moderation
    is_removed          BOOLEAN     NOT NULL DEFAULT FALSE,
    removed_at          TIMESTAMPTZ,
    removed_by          UUID        REFERENCES public.users(id),
    removal_reason      TEXT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ
);

COMMENT ON TABLE public.posts IS 'Main feed content items.';

CREATE TABLE IF NOT EXISTS public.post_media (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id             UUID        NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
    media_type          TEXT        NOT NULL CHECK (media_type IN ('image', 'video')),
    url                 TEXT        NOT NULL,
    thumbnail_url       TEXT,
    width               INTEGER,
    height              INTEGER,
    duration_sec        INTEGER,
    size_bytes          BIGINT,
    sort_order          INTEGER     NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.post_likes (
    post_id             UUID        NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
    user_id             UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    liked_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (post_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.post_saves (
    post_id             UUID        NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
    user_id             UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    saved_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (post_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.post_comments (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    post_id             UUID        NOT NULL REFERENCES public.posts(id) ON DELETE CASCADE,
    author_id           UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    parent_id           UUID        REFERENCES public.post_comments(id) ON DELETE CASCADE,
    content             TEXT        NOT NULL,
    like_count          INTEGER     NOT NULL DEFAULT 0,
    is_removed          BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ── Stories ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.stories (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    author_id           UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

    media_type          TEXT        NOT NULL CHECK (media_type IN ('image', 'video', 'text')),
    media_url           TEXT,
    thumbnail_url       TEXT,
    text_content        TEXT,
    text_style          JSONB,                             -- font, color, background config

    -- Location
    location            GEOMETRY(POINT, 4326),
    geohash             TEXT,
    location_name       TEXT,

    -- Audience
    visibility          TEXT        NOT NULL DEFAULT 'area'
                            CHECK (visibility IN ('public', 'area', 'connections')),

    -- Lifecycle
    expires_at          TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '24 hours'),
    is_archived         BOOLEAN     NOT NULL DEFAULT FALSE,  -- archived after expiry

    -- Engagement
    view_count          INTEGER     NOT NULL DEFAULT 0,
    reply_count         INTEGER     NOT NULL DEFAULT 0,

    -- Moderation
    is_removed          BOOLEAN     NOT NULL DEFAULT FALSE,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.story_elements (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    story_id            UUID        NOT NULL REFERENCES public.stories(id) ON DELETE CASCADE,
    element_type        TEXT        NOT NULL CHECK (element_type IN ('poll', 'question', 'quiz', 'music', 'location_tag', 'mention')),
    element_data        JSONB       NOT NULL DEFAULT '{}',  -- type-specific configuration
    sort_order          INTEGER     NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.story_views (
    story_id            UUID        NOT NULL REFERENCES public.stories(id) ON DELETE CASCADE,
    viewer_id           UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    viewed_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (story_id, viewer_id)
);

-- ── Reels ─────────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.reels (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    author_id           UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

    -- Video assets
    raw_video_url       TEXT,                              -- original upload
    processed_video_url TEXT,                              -- HLS/DASH stream after transcoding
    thumbnail_url       TEXT        NOT NULL,
    duration_sec        INTEGER     NOT NULL,
    width               INTEGER,
    height              INTEGER,
    size_bytes          BIGINT,

    -- Processing state
    processing_status   TEXT        NOT NULL DEFAULT 'pending'
                            CHECK (processing_status IN ('pending', 'processing', 'ready', 'failed')),
    processing_error    TEXT,
    processed_at        TIMESTAMPTZ,

    -- Content
    caption             TEXT,
    audio_name          TEXT,                              -- original audio or song name
    hashtags            TEXT[]      NOT NULL DEFAULT '{}',

    -- Location
    location            GEOMETRY(POINT, 4326),
    geohash             TEXT,
    location_name       TEXT,

    -- Visibility
    visibility          TEXT        NOT NULL DEFAULT 'public'
                            CHECK (visibility IN ('public', 'area', 'connections')),

    -- Engagement
    view_count          INTEGER     NOT NULL DEFAULT 0,
    like_count          INTEGER     NOT NULL DEFAULT 0,
    comment_count       INTEGER     NOT NULL DEFAULT 0,
    share_count         INTEGER     NOT NULL DEFAULT 0,
    avg_watch_percent   REAL        NOT NULL DEFAULT 0.0,  -- 0.0-1.0

    -- Admin controls
    is_boosted          BOOLEAN     NOT NULL DEFAULT FALSE,
    is_suppressed       BOOLEAN     NOT NULL DEFAULT FALSE,
    is_removed          BOOLEAN     NOT NULL DEFAULT FALSE,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    deleted_at          TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS public.reel_watch_events (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    reel_id             UUID        NOT NULL REFERENCES public.reels(id) ON DELETE CASCADE,
    viewer_id           UUID        REFERENCES public.users(id) ON DELETE SET NULL,
    watch_percent       REAL        NOT NULL CHECK (watch_percent BETWEEN 0.0 AND 1.0),
    watch_duration_sec  INTEGER,
    source              TEXT        CHECK (source IN ('feed', 'explore', 'profile', 'share')),
    watched_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 5: BUSINESS DISCOVERY
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.businesses (
    id                      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id                UUID        REFERENCES public.users(id) ON DELETE SET NULL,

    -- Identity
    name                    TEXT        NOT NULL,
    slug                    TEXT        UNIQUE NOT NULL,   -- URL-friendly name
    category                TEXT        NOT NULL,          -- e.g. 'restaurant', 'gym', 'salon'
    subcategory             TEXT,
    description             TEXT,
    tagline                 TEXT,

    -- Media
    logo_url                TEXT,
    cover_photo_url         TEXT,
    photos                  TEXT[]      NOT NULL DEFAULT '{}',

    -- Contact
    phone                   TEXT,
    email                   TEXT,
    website                 TEXT,
    instagram_handle        TEXT,

    -- Location
    location                GEOMETRY(POINT, 4326) NOT NULL,
    geohash                 TEXT        NOT NULL,
    address_line1           TEXT        NOT NULL,
    address_line2           TEXT,
    city                    TEXT        NOT NULL,
    area                    TEXT,

    -- Status flags
    is_verified             BOOLEAN     NOT NULL DEFAULT FALSE,
    verified_at             TIMESTAMPTZ,
    verified_by             UUID        REFERENCES public.users(id),
    is_new_opening          BOOLEAN     NOT NULL DEFAULT FALSE,
    new_badge_expires_at    TIMESTAMPTZ,
    is_active               BOOLEAN     NOT NULL DEFAULT TRUE,
    is_featured             BOOLEAN     NOT NULL DEFAULT FALSE,  -- editorial feature

    -- Advertising
    is_advertising          BOOLEAN     NOT NULL DEFAULT FALSE,
    ad_campaign_id          TEXT,
    ad_starts_at            TIMESTAMPTZ,
    ad_ends_at              TIMESTAMPTZ,
    ad_radius_km            REAL,                           -- show to users within this radius

    -- Analytics
    view_count              INTEGER     NOT NULL DEFAULT 0,
    click_count             INTEGER     NOT NULL DEFAULT 0,
    save_count              INTEGER     NOT NULL DEFAULT 0,
    avg_rating              REAL,
    review_count            INTEGER     NOT NULL DEFAULT 0,

    created_at              TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.businesses IS 'Local business listings with location and advertising support.';

CREATE TABLE IF NOT EXISTS public.business_hours (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id         UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    day_of_week         INTEGER     NOT NULL CHECK (day_of_week BETWEEN 0 AND 6),  -- 0=Sunday
    opens_at            TIME,
    closes_at           TIME,
    is_closed           BOOLEAN     NOT NULL DEFAULT FALSE,
    UNIQUE (business_id, day_of_week)
);

CREATE TABLE IF NOT EXISTS public.business_interactions (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id         UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    user_id             UUID        REFERENCES public.users(id) ON DELETE SET NULL,
    interaction_type    TEXT        NOT NULL CHECK (interaction_type IN ('view', 'click', 'call', 'directions', 'website', 'save', 'unsave', 'ad_impression', 'ad_click')),
    metadata            JSONB       NOT NULL DEFAULT '{}',
    occurred_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.business_reviews (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    business_id         UUID        NOT NULL REFERENCES public.businesses(id) ON DELETE CASCADE,
    reviewer_id         UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    rating              INTEGER     NOT NULL CHECK (rating BETWEEN 1 AND 5),
    review_text         TEXT,
    is_verified_visit   BOOLEAN     NOT NULL DEFAULT FALSE,
    is_removed          BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (business_id, reviewer_id)
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 6: COMMUNITY — POLLS, EVENTS, MARKETPLACE
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.polls (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    creator_id          UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    question            TEXT        NOT NULL,
    description         TEXT,

    -- Location scope
    location            GEOMETRY(POINT, 4326),
    geohash             TEXT,
    scope_radius_km     REAL        NOT NULL DEFAULT 5.0,

    is_anonymous        BOOLEAN     NOT NULL DEFAULT FALSE,
    allows_multiple     BOOLEAN     NOT NULL DEFAULT FALSE,
    expires_at          TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '7 days'),
    total_votes         INTEGER     NOT NULL DEFAULT 0,
    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.poll_options (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    poll_id             UUID        NOT NULL REFERENCES public.polls(id) ON DELETE CASCADE,
    option_text         TEXT        NOT NULL,
    vote_count          INTEGER     NOT NULL DEFAULT 0,
    sort_order          INTEGER     NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS public.poll_votes (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    poll_id             UUID        NOT NULL REFERENCES public.polls(id) ON DELETE CASCADE,
    option_id           UUID        NOT NULL REFERENCES public.poll_options(id) ON DELETE CASCADE,
    voter_id            UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    voted_at            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (poll_id, voter_id, option_id)
);

CREATE TABLE IF NOT EXISTS public.events (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    organizer_id        UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

    title               TEXT        NOT NULL,
    description         TEXT,
    cover_photo_url     TEXT,
    category            TEXT,                              -- 'meetup', 'party', 'sports', etc.

    -- When
    starts_at           TIMESTAMPTZ NOT NULL,
    ends_at             TIMESTAMPTZ,
    is_recurring        BOOLEAN     NOT NULL DEFAULT FALSE,
    recurrence_rule     TEXT,                              -- iCal RRULE string

    -- Where
    location            GEOMETRY(POINT, 4326),
    geohash             TEXT,
    venue_name          TEXT,
    address             TEXT,
    is_online           BOOLEAN     NOT NULL DEFAULT FALSE,
    online_link         TEXT,

    -- Audience
    visibility          TEXT        NOT NULL DEFAULT 'public'
                            CHECK (visibility IN ('public', 'area', 'connections', 'invite_only')),
    max_attendees       INTEGER,
    requires_approval   BOOLEAN     NOT NULL DEFAULT FALSE,

    -- Stats
    rsvp_going_count    INTEGER     NOT NULL DEFAULT 0,
    rsvp_maybe_count    INTEGER     NOT NULL DEFAULT 0,
    view_count          INTEGER     NOT NULL DEFAULT 0,

    is_cancelled        BOOLEAN     NOT NULL DEFAULT FALSE,
    cancellation_note   TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.event_rsvps (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id            UUID        NOT NULL REFERENCES public.events(id) ON DELETE CASCADE,
    user_id             UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    status              TEXT        NOT NULL CHECK (status IN ('going', 'maybe', 'not_going', 'invited', 'waitlisted')),
    rsvped_at           TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (event_id, user_id)
);

CREATE TABLE IF NOT EXISTS public.marketplace_listings (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    seller_id           UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,

    title               TEXT        NOT NULL,
    description         TEXT,
    category            TEXT        NOT NULL,
    condition           TEXT        CHECK (condition IN ('new', 'like_new', 'good', 'fair', 'for_parts')),

    -- Price
    price               NUMERIC(12,2),
    currency            TEXT        NOT NULL DEFAULT 'INR',
    is_negotiable       BOOLEAN     NOT NULL DEFAULT FALSE,
    is_free             BOOLEAN     NOT NULL DEFAULT FALSE,

    -- Location
    location            GEOMETRY(POINT, 4326),
    geohash             TEXT,
    city                TEXT,

    -- Status
    status              TEXT        NOT NULL DEFAULT 'active'
                            CHECK (status IN ('active', 'sold', 'reserved', 'expired', 'removed')),
    sold_to             UUID        REFERENCES public.users(id),
    sold_at             TIMESTAMPTZ,

    -- Analytics
    view_count          INTEGER     NOT NULL DEFAULT 0,
    save_count          INTEGER     NOT NULL DEFAULT 0,
    contact_count       INTEGER     NOT NULL DEFAULT 0,

    expires_at          TIMESTAMPTZ NOT NULL DEFAULT (NOW() + INTERVAL '30 days'),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.marketplace_images (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    listing_id          UUID        NOT NULL REFERENCES public.marketplace_listings(id) ON DELETE CASCADE,
    url                 TEXT        NOT NULL,
    is_primary          BOOLEAN     NOT NULL DEFAULT FALSE,
    sort_order          INTEGER     NOT NULL DEFAULT 0
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 7: MODERATION & NOTIFICATIONS
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.reports (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_id         UUID        NOT NULL REFERENCES public.users(id) ON DELETE SET NULL,

    -- What is being reported (polymorphic)
    target_type         TEXT        NOT NULL CHECK (target_type IN (
                            'user', 'post', 'story', 'reel', 'message',
                            'comment', 'business', 'event', 'listing'
                        )),
    target_id           UUID        NOT NULL,

    reason              TEXT        NOT NULL CHECK (reason IN (
                            'spam', 'harassment', 'hate_speech', 'violence',
                            'nudity', 'misinformation', 'scam', 'self_harm', 'other'
                        )),
    details             TEXT,                              -- user's written explanation

    -- Admin handling
    status              TEXT        NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'reviewing', 'resolved', 'dismissed')),
    reviewed_by         UUID        REFERENCES public.users(id),
    reviewed_at         TIMESTAMPTZ,
    resolution          TEXT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.notifications (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    recipient_id        UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    sender_id           UUID        REFERENCES public.users(id) ON DELETE SET NULL,

    notification_type   TEXT        NOT NULL CHECK (notification_type IN (
                            'wave_received', 'wave_accepted', 'connection_made',
                            'message_received', 'post_liked', 'post_commented',
                            'story_viewed', 'reel_liked', 'mention',
                            'event_rsvp', 'event_reminder', 'nearby_activity',
                            'system', 'admin', 'promo'
                        )),
    title               TEXT        NOT NULL,
    body                TEXT        NOT NULL,

    -- Optional deep link data
    deep_link_type      TEXT,                              -- 'post', 'profile', 'event', etc.
    deep_link_id        UUID,

    -- Delivery
    is_read             BOOLEAN     NOT NULL DEFAULT FALSE,
    read_at             TIMESTAMPTZ,
    is_push_sent        BOOLEAN     NOT NULL DEFAULT FALSE,
    push_sent_at        TIMESTAMPTZ,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at          TIMESTAMPTZ DEFAULT (NOW() + INTERVAL '30 days')
);

CREATE TABLE IF NOT EXISTS public.location_history (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id             UUID        NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
    location            GEOMETRY(POINT, 4326) NOT NULL,
    geohash             TEXT        NOT NULL,
    accuracy_meters     REAL,
    source              TEXT        CHECK (source IN ('app_foreground', 'app_background', 'manual')),
    recorded_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 8: ADMIN SYSTEM
-- ─────────────────────────────────────────────────────────────────────────────

CREATE TABLE IF NOT EXISTS public.admin_users (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    email               TEXT        UNIQUE NOT NULL,
    password_hash       TEXT        NOT NULL,              -- bcrypt hash
    full_name           TEXT        NOT NULL,
    role                TEXT        NOT NULL DEFAULT 'moderator'
                            CHECK (role IN ('super_admin', 'admin', 'moderator', 'analyst', 'support')),
    -- Role capabilities
    can_ban_users       BOOLEAN     NOT NULL DEFAULT FALSE,
    can_remove_content  BOOLEAN     NOT NULL DEFAULT FALSE,
    can_manage_features BOOLEAN     NOT NULL DEFAULT FALSE,
    can_view_analytics  BOOLEAN     NOT NULL DEFAULT TRUE,
    can_manage_admins   BOOLEAN     NOT NULL DEFAULT FALSE,

    is_active           BOOLEAN     NOT NULL DEFAULT TRUE,
    last_login_at       TIMESTAMPTZ,
    login_ip            INET,
    two_fa_enabled      BOOLEAN     NOT NULL DEFAULT FALSE,
    two_fa_secret       TEXT,

    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by          UUID        REFERENCES public.admin_users(id)
);

COMMENT ON TABLE public.admin_users IS 'Admin panel accounts. Completely separate from public.users.';

-- Immutable audit log — no UPDATE or DELETE allowed (enforced via trigger)
CREATE TABLE IF NOT EXISTS public.admin_audit_log (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_id            UUID        NOT NULL REFERENCES public.admin_users(id),
    admin_email         TEXT        NOT NULL,              -- denormalized in case admin is deleted

    action              TEXT        NOT NULL,              -- e.g. 'ban_user', 'remove_post', 'toggle_feature'
    target_type         TEXT,                              -- 'user', 'post', 'feature_flag', etc.
    target_id           TEXT,                              -- UUID or key of the target

    -- Snapshot of what changed
    before_state        JSONB,
    after_state         JSONB,
    notes               TEXT,

    -- Request metadata
    ip_address          INET,
    user_agent          TEXT,
    occurred_at         TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.admin_audit_log IS 'Immutable audit trail. Every admin action is logged here permanently.';

-- Prevent UPDATE/DELETE on audit log
CREATE OR REPLACE FUNCTION public.prevent_audit_modification()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Admin audit log is immutable — modification not allowed.';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trg_audit_immutable_update
    BEFORE UPDATE ON public.admin_audit_log
    FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_modification();

CREATE OR REPLACE TRIGGER trg_audit_immutable_delete
    BEFORE DELETE ON public.admin_audit_log
    FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_modification();

-- ── Feature Flags ─────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.feature_flags (
    id                  UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    flag_key            TEXT        UNIQUE NOT NULL,       -- e.g. 'waves_enabled'
    display_name        TEXT        NOT NULL,
    description         TEXT,
    category            TEXT        NOT NULL CHECK (category IN (
                            'core', 'social', 'messaging', 'content', 'discovery',
                            'monetization', 'admin', 'experimental'
                        )),

    -- Global toggle
    is_enabled          BOOLEAN     NOT NULL DEFAULT TRUE,

    -- Subscription gate (NULL = available to all tiers)
    required_tier       TEXT        CHECK (required_tier IN ('basic', 'pro', 'elite')),

    -- Rollout controls
    rollout_percentage  INTEGER     NOT NULL DEFAULT 100
                            CHECK (rollout_percentage BETWEEN 0 AND 100),
    enabled_for_admins  BOOLEAN     NOT NULL DEFAULT TRUE,  -- always on for admins in testing

    -- Metadata
    is_deprecated       BOOLEAN     NOT NULL DEFAULT FALSE,
    deprecation_note    TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.feature_flags IS 'Single source of truth for all feature toggles. Both backend and admin panel read from here.';

-- ── App Configuration ─────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.app_config (
    key                 TEXT        PRIMARY KEY,
    value               TEXT        NOT NULL,
    value_type          TEXT        NOT NULL DEFAULT 'string'
                            CHECK (value_type IN ('string', 'integer', 'float', 'boolean', 'json')),
    description         TEXT,
    category            TEXT        NOT NULL DEFAULT 'general',
    is_public           BOOLEAN     NOT NULL DEFAULT FALSE,  -- safe to send to client
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_by          UUID        REFERENCES public.admin_users(id)
);

COMMENT ON TABLE public.app_config IS 'Runtime configuration editable from admin panel without code deploy.';

-- ── Secrets ───────────────────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.secrets (
    key                 TEXT        PRIMARY KEY,
    encrypted_value     TEXT        NOT NULL,              -- AES-256 encrypted
    description         TEXT,
    last_rotated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    rotated_by          UUID        REFERENCES public.admin_users(id),
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE public.secrets IS 'Encrypted credentials. Managed through admin panel. Never in plaintext.';

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 9: TRIGGERS — Auto-update timestamps
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply to all tables with updated_at
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'users', 'conversations', 'posts', 'reels', 'businesses',
        'events', 'marketplace_listings', 'admin_users',
        'feature_flags', 'app_config'
    ] LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_%s_updated_at ON public.%I;
             CREATE TRIGGER trg_%s_updated_at
             BEFORE UPDATE ON public.%I
             FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();',
            t, t, t, t
        );
    END LOOP;
END
$$;

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 10: INDEXES
-- ─────────────────────────────────────────────────────────────────────────────

-- Users
CREATE INDEX IF NOT EXISTS idx_users_email           ON public.users (email);
CREATE INDEX IF NOT EXISTS idx_users_mobile          ON public.users (mobile_number);
CREATE INDEX IF NOT EXISTS idx_users_username        ON public.users (username);
CREATE INDEX IF NOT EXISTS idx_users_geohash         ON public.users (geohash) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_users_colony_score    ON public.users (colony_score DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_users_last_active     ON public.users (last_active_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_users_premium_tier    ON public.users (premium_tier) WHERE is_premium = TRUE;
-- PostGIS spatial index for user location queries (find nearby users)
CREATE INDEX IF NOT EXISTS idx_users_location_geo    ON public.users USING GIST (location) WHERE deleted_at IS NULL;
-- Full-text search on username and full_name
CREATE INDEX IF NOT EXISTS idx_users_name_trgm       ON public.users USING GIN (full_name gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_users_username_trgm   ON public.users USING GIN (username gin_trgm_ops);

-- Sessions
CREATE INDEX IF NOT EXISTS idx_sessions_user         ON public.user_sessions (user_id, is_valid);
CREATE INDEX IF NOT EXISTS idx_sessions_token_family ON public.user_sessions (token_family);
CREATE INDEX IF NOT EXISTS idx_sessions_expires      ON public.user_sessions (refresh_expires_at) WHERE is_valid = TRUE;

-- Devices
CREATE INDEX IF NOT EXISTS idx_devices_user          ON public.user_devices (user_id);
CREATE INDEX IF NOT EXISTS idx_devices_push_token    ON public.user_devices (push_token) WHERE push_token IS NOT NULL;

-- Waves
CREATE INDEX IF NOT EXISTS idx_waves_receiver        ON public.waves (receiver_id, status);
CREATE INDEX IF NOT EXISTS idx_waves_sender          ON public.waves (sender_id, status);
CREATE INDEX IF NOT EXISTS idx_waves_expires         ON public.waves (expires_at) WHERE status = 'pending';

-- Connections
CREATE INDEX IF NOT EXISTS idx_connections_a         ON public.connections (user_a_id, status);
CREATE INDEX IF NOT EXISTS idx_connections_b         ON public.connections (user_b_id, status);
CREATE INDEX IF NOT EXISTS idx_connections_last_int  ON public.connections (last_interaction_at DESC);

-- Conversations & Messages
CREATE INDEX IF NOT EXISTS idx_conversations_type    ON public.conversations (conversation_type);
CREATE INDEX IF NOT EXISTS idx_conversations_area    ON public.conversations (area_zone_id) WHERE conversation_type = 'area_group';
CREATE INDEX IF NOT EXISTS idx_conv_participants_usr ON public.conversation_participants (user_id);
CREATE INDEX IF NOT EXISTS idx_messages_conv         ON public.messages (conversation_id, sent_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_sender       ON public.messages (sender_id, sent_at DESC);
CREATE INDEX IF NOT EXISTS idx_messages_expires      ON public.messages (expires_at) WHERE expires_at IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_message_reads         ON public.message_reads (user_id, read_at DESC);

-- Posts
CREATE INDEX IF NOT EXISTS idx_posts_author          ON public.posts (author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_posts_created         ON public.posts (created_at DESC) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_posts_geohash         ON public.posts (geohash) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_posts_location_geo    ON public.posts USING GIST (location) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_posts_likes           ON public.posts (like_count DESC) WHERE deleted_at IS NULL;

-- Stories
CREATE INDEX IF NOT EXISTS idx_stories_author        ON public.stories (author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_stories_expires       ON public.stories (expires_at) WHERE is_removed = FALSE;
CREATE INDEX IF NOT EXISTS idx_stories_geohash       ON public.stories (geohash);
CREATE INDEX IF NOT EXISTS idx_stories_location_geo  ON public.stories USING GIST (location);

-- Reels
CREATE INDEX IF NOT EXISTS idx_reels_author          ON public.reels (author_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reels_status          ON public.reels (processing_status);
CREATE INDEX IF NOT EXISTS idx_reels_location_geo    ON public.reels USING GIST (location) WHERE deleted_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_reels_views           ON public.reels (view_count DESC) WHERE deleted_at IS NULL;

-- Businesses
CREATE INDEX IF NOT EXISTS idx_businesses_location_geo ON public.businesses USING GIST (location) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_businesses_geohash    ON public.businesses (geohash) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_businesses_category   ON public.businesses (category) WHERE is_active = TRUE;
CREATE INDEX IF NOT EXISTS idx_businesses_advertising ON public.businesses (ad_ends_at) WHERE is_advertising = TRUE;
CREATE INDEX IF NOT EXISTS idx_businesses_name_trgm  ON public.businesses USING GIN (name gin_trgm_ops);

-- Events
CREATE INDEX IF NOT EXISTS idx_events_starts_at      ON public.events (starts_at) WHERE is_cancelled = FALSE;
CREATE INDEX IF NOT EXISTS idx_events_location_geo   ON public.events USING GIST (location) WHERE is_cancelled = FALSE;
CREATE INDEX IF NOT EXISTS idx_events_geohash        ON public.events (geohash) WHERE is_cancelled = FALSE;

-- Marketplace
CREATE INDEX IF NOT EXISTS idx_marketplace_seller    ON public.marketplace_listings (seller_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_marketplace_location_geo ON public.marketplace_listings USING GIST (location) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS idx_marketplace_category  ON public.marketplace_listings (category, status);
CREATE INDEX IF NOT EXISTS idx_marketplace_expires   ON public.marketplace_listings (expires_at) WHERE status = 'active';

-- Notifications
CREATE INDEX IF NOT EXISTS idx_notifications_recv    ON public.notifications (recipient_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_unread  ON public.notifications (recipient_id, is_read) WHERE is_read = FALSE;

-- Location history
CREATE INDEX IF NOT EXISTS idx_location_history_usr  ON public.location_history (user_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_location_history_geo  ON public.location_history USING GIST (location);

-- Admin
CREATE INDEX IF NOT EXISTS idx_audit_log_admin       ON public.admin_audit_log (admin_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_log_target      ON public.admin_audit_log (target_type, target_id);

-- Feature flags
CREATE INDEX IF NOT EXISTS idx_feature_flags_key     ON public.feature_flags (flag_key);
CREATE INDEX IF NOT EXISTS idx_feature_flags_cat     ON public.feature_flags (category, is_enabled);

-- ─────────────────────────────────────────────────────────────────────────────
-- SECTION 11: ROW LEVEL SECURITY (RLS) — Basics
-- Enable RLS so PostgREST/Supabase respects auth properly
-- ─────────────────────────────────────────────────────────────────────────────

ALTER TABLE public.users                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_sessions            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_devices             ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.waves                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connections              ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversation_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages                 ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.posts                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.post_comments            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stories                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reels                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.marketplace_listings     ENABLE ROW LEVEL SECURITY;

-- Public read-only tables (no RLS needed for reads)
ALTER TABLE public.feature_flags            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.app_config               ENABLE ROW LEVEL SECURITY;

-- ─────────────────────────────────────────────────────────────────────────────
-- MARK MIGRATION AS APPLIED
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO public._colony_migrations (version, description)
VALUES ('001', 'Initial Colony schema: users, social, messaging, content, discovery, admin')
ON CONFLICT (version) DO NOTHING;
