-- =============================================================================
-- 002_app_config.sql — Seed default app configuration values
-- Run after 001_schema.sql
-- Idempotent: uses INSERT ... ON CONFLICT DO UPDATE
-- =============================================================================

INSERT INTO public.app_config (key, value, value_type, description, category, is_public)
VALUES

-- ── Discovery & Location ──────────────────────────────────────────────────────
('discovery.default_radius_km',         '5',         'float',   'Default search radius for nearby users and content (km)',          'discovery',  TRUE ),
('discovery.max_radius_km',             '50',        'float',   'Maximum allowed search radius (km)',                               'discovery',  TRUE ),
('discovery.min_radius_km',             '0.5',       'float',   'Minimum allowed search radius (km)',                               'discovery',  TRUE ),
('discovery.nearby_users_limit',        '50',        'integer', 'Max nearby users returned in a single query',                      'discovery',  TRUE ),
('discovery.location_update_interval_sec', '30',     'integer', 'How often the app should push location updates (seconds)',         'discovery',  TRUE ),
('discovery.location_stale_minutes',    '15',        'integer', 'Consider a user offline if last location is older than this',      'discovery',  FALSE),

-- ── Waves ─────────────────────────────────────────────────────────────────────
('waves.expiry_hours',                  '48',        'integer', 'Hours before an unresponded wave expires',                         'social',     TRUE ),
('waves.daily_limit_free',              '10',        'integer', 'Waves a free user can send per day',                              'social',     TRUE ),
('waves.daily_limit_basic',             '30',        'integer', 'Waves a Basic tier user can send per day',                        'social',     TRUE ),
('waves.daily_limit_pro',               '100',       'integer', 'Waves a Pro tier user can send per day',                          'social',     TRUE ),
('waves.daily_limit_elite',             '500',       'integer', 'Waves an Elite tier user can send per day',                       'social',     TRUE ),
('waves.super_wave_daily_limit_basic',  '3',         'integer', 'Super waves a Basic user can send per day',                       'social',     TRUE ),
('waves.super_wave_daily_limit_pro',    '10',        'integer', 'Super waves a Pro user can send per day',                         'social',     TRUE ),
('waves.super_wave_daily_limit_elite',  '50',        'integer', 'Super waves an Elite user can send per day',                      'social',     TRUE ),

-- ── Messaging ─────────────────────────────────────────────────────────────────
('messaging.max_message_length',        '2000',      'integer', 'Maximum character count for a single message',                     'messaging',  TRUE ),
('messaging.max_group_members',         '200',       'integer', 'Maximum members in a user-created group',                         'messaging',  TRUE ),
('messaging.max_media_size_mb',         '50',        'integer', 'Maximum file size for media attachments (MB)',                     'messaging',  TRUE ),
('messaging.disappearing_min_seconds',  '30',        'integer', 'Minimum TTL for disappearing messages (seconds)',                  'messaging',  TRUE ),
('messaging.disappearing_max_days',     '7',         'integer', 'Maximum TTL for disappearing messages (days)',                     'messaging',  TRUE ),
('messaging.area_group_radius_km',      '2',         'float',   'Radius that defines an area group zone (km)',                      'messaging',  FALSE),

-- ── Content ───────────────────────────────────────────────────────────────────
('content.post_max_length',             '2000',      'integer', 'Maximum character count for a post',                              'content',    TRUE ),
('content.post_max_photos',             '10',        'integer', 'Maximum photos per post',                                          'content',    TRUE ),
('content.post_daily_limit_free',       '5',         'integer', 'Posts a free user can create per day',                            'content',    TRUE ),
('content.post_daily_limit_basic',      '20',        'integer', 'Posts a Basic tier user can create per day',                      'content',    TRUE ),
('content.story_duration_hours',        '24',        'integer', 'How long a story is visible before expiring (hours)',             'content',    TRUE ),
('content.reel_max_duration_sec',       '60',        'integer', 'Maximum reel video duration (seconds)',                           'content',    TRUE ),
('content.reel_max_size_mb',            '200',       'integer', 'Maximum reel video file size (MB)',                               'content',    TRUE ),
('content.bio_max_length',              '300',       'integer', 'Maximum character count for user bio',                            'content',    TRUE ),
('content.vibe_tags_max',               '10',        'integer', 'Maximum number of vibe tags a user can select',                   'content',    TRUE ),
('content.mood_status_max_length',      '100',       'integer', 'Maximum character count for mood status',                         'content',    TRUE ),

-- ── Marketplace ───────────────────────────────────────────────────────────────
('marketplace.listing_expiry_days',     '30',        'integer', 'Days before a marketplace listing expires',                       'marketplace', TRUE ),
('marketplace.max_photos_per_listing',  '8',         'integer', 'Maximum photos per marketplace listing',                          'marketplace', TRUE ),
('marketplace.max_listings_per_user',   '20',        'integer', 'Maximum active listings per user',                                'marketplace', TRUE ),
('marketplace.search_radius_km',        '20',        'float',   'Default marketplace search radius (km)',                           'marketplace', TRUE ),

-- ── Moderation ────────────────────────────────────────────────────────────────
('moderation.auto_review_threshold',    '3',         'integer', 'Report count that triggers admin review queue',                    'moderation', FALSE),
('moderation.auto_remove_threshold',    '10',        'integer', 'Report count that triggers temporary auto-removal',               'moderation', FALSE),
('moderation.wave_flood_window_min',    '1',         'integer', 'Minutes window for wave flood detection',                         'moderation', FALSE),
('moderation.wave_flood_limit',         '5',         'integer', 'Max waves in flood window before throttling',                     'moderation', FALSE),
('moderation.new_user_grace_days',      '3',         'integer', 'Days after signup with relaxed limits for new users',             'moderation', FALSE),

-- ── Algorithm ─────────────────────────────────────────────────────────────────
('algorithm.feed_fresh_weight',         '0.4',       'float',   'Weight of recency in feed ranking (0-1)',                         'algorithm',  FALSE),
('algorithm.feed_engagement_weight',    '0.35',      'float',   'Weight of engagement rate in feed ranking (0-1)',                  'algorithm',  FALSE),
('algorithm.feed_distance_weight',      '0.25',      'float',   'Weight of proximity in feed ranking (0-1)',                        'algorithm',  FALSE),
('algorithm.boosted_post_multiplier',   '3.0',       'float',   'Feed score multiplier for admin-boosted posts',                   'algorithm',  FALSE),
('algorithm.premium_discovery_boost',   '1.5',       'float',   'Discovery score multiplier for premium users',                    'algorithm',  FALSE),

-- ── UI / Client ──────────────────────────────────────────────────────────────
('ui.app_store_url_android',            'https://play.google.com/store/apps/details?id=com.colony', 'string', 'Google Play Store URL', 'ui', TRUE),
('ui.app_store_url_ios',                'https://apps.apple.com/app/colony',                        'string', 'Apple App Store URL',   'ui', TRUE),
('ui.support_email',                    'support@colony.app',    'string',  'Public support email address',                         'ui', TRUE),
('ui.min_app_version_android',          '1.0.0',     'string',  'Minimum supported Android app version (force update below this)', 'ui', TRUE),
('ui.min_app_version_ios',              '1.0.0',     'string',  'Minimum supported iOS app version (force update below this)',     'ui', TRUE),
('ui.maintenance_mode',                 'false',     'boolean', 'Set to true to show maintenance screen to all users',             'ui', TRUE),
('ui.maintenance_message',              'Colony is undergoing scheduled maintenance. Back soon!', 'string', 'Maintenance mode message shown to users', 'ui', TRUE),

-- ── Security ─────────────────────────────────────────────────────────────────
('security.session_access_ttl_minutes', '60',        'integer', 'Access token TTL in minutes',                                     'security',   FALSE),
('security.session_refresh_ttl_days',   '30',        'integer', 'Refresh token TTL in days',                                       'security',   FALSE),
('security.max_devices_per_user',       '5',         'integer', 'Maximum concurrent device sessions per user',                     'security',   FALSE),
('security.max_login_attempts',         '5',         'integer', 'Failed login attempts before temporary lockout',                  'security',   FALSE),
('security.lockout_minutes',            '15',        'integer', 'Login lockout duration after max failed attempts (minutes)',       'security',   FALSE),
('security.rooted_device_allowed',      'false',     'boolean', 'Whether to allow app usage on rooted/jailbroken devices',         'security',   FALSE),
('security.emulator_allowed',           'true',      'boolean', 'Whether to allow app usage on emulators (dev mode)',              'security',   FALSE)

ON CONFLICT (key) DO UPDATE SET
    value        = EXCLUDED.value,
    value_type   = EXCLUDED.value_type,
    description  = EXCLUDED.description,
    category     = EXCLUDED.category,
    is_public    = EXCLUDED.is_public,
    updated_at   = NOW();

-- Verify count
DO $$
DECLARE cfg_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO cfg_count FROM public.app_config;
    RAISE NOTICE 'App config seeded: % total keys', cfg_count;
END
$$;
