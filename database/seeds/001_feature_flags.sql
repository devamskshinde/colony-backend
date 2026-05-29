-- =============================================================================
-- 001_feature_flags.sql — Seed all Colony feature flags
-- Run after 001_schema.sql
-- Idempotent: uses INSERT ... ON CONFLICT DO UPDATE
-- =============================================================================

INSERT INTO public.feature_flags (flag_key, display_name, description, category, is_enabled, required_tier, rollout_percentage)
VALUES

-- ── Core Features ─────────────────────────────────────────────────────────────
('user_registration',       'User Registration',          'Allow new users to sign up',                        'core',          TRUE,  NULL,    100),
('user_login',              'User Login',                 'Allow users to log in',                             'core',          TRUE,  NULL,    100),
('email_verification',      'Email Verification',         'Require email verification on signup',              'core',          TRUE,  NULL,    100),
('mobile_verification',     'Mobile Verification',        'Require mobile OTP verification on signup',         'core',          TRUE,  NULL,    100),
('password_reset',          'Password Reset',             'Allow users to reset their password via email',     'core',          TRUE,  NULL,    100),
('account_deletion',        'Account Deletion',           'Allow users to permanently delete their account',   'core',          TRUE,  NULL,    100),
('profile_editing',         'Profile Editing',            'Allow users to edit their profile info',            'core',          TRUE,  NULL,    100),
('profile_photo_upload',    'Profile Photo Upload',       'Allow profile and cover photo uploads',             'core',          TRUE,  NULL,    100),
('vibe_tags',               'Vibe Tags',                  'Interest tags on user profiles',                    'core',          TRUE,  NULL,    100),
('mood_status',             'Mood Status',                'Short mood message visible to nearby users',        'core',          TRUE,  NULL,    100),
('location_sharing',        'Location Sharing',           'Share approximate location for discovery',          'core',          TRUE,  NULL,    100),
('colony_score',            'Colony Score',               'Gamification score based on community activity',    'core',          TRUE,  NULL,    100),
('level_titles',            'Level Titles',               'Titles that change as colony score grows',          'core',          TRUE,  NULL,    100),

-- ── Social Features ────────────────────────────────────────────────────────────
('waves',                   'Waves',                      'Send interest expressions to nearby users',         'social',        TRUE,  NULL,    100),
('super_waves',             'Super Waves',                'Premium wave with higher visibility',               'social',        TRUE,  'basic', 100),
('anonymous_waves',         'Anonymous Waves',            'Send waves without revealing identity',             'social',        TRUE,  'pro',   100),
('connections',             'Connections',                'Mutual wave creates a connection',                  'social',        TRUE,  NULL,    100),
('user_blocking',           'User Blocking',              'Block another user',                               'social',        TRUE,  NULL,    100),
('user_search',             'User Search',                'Search for users by name or username',              'social',        TRUE,  NULL,    100),
('nearby_users',            'Nearby Users',               'See users in your area',                           'social',        TRUE,  NULL,    100),
('user_profiles',           'User Profiles',              'View other user profiles',                         'social',        TRUE,  NULL,    100),
('follow_activity_feed',    'Connection Activity',        'See activity from your connections',               'social',        TRUE,  NULL,    100),

-- ── Messaging Features ──────────────────────────────────────────────────────────
('direct_messaging',        'Direct Messaging',           'Private 1-1 chat between connections',             'messaging',     TRUE,  NULL,    100),
('area_group_chat',         'Area Group Chat',            'Auto-created group chat for a geographic area',    'messaging',     TRUE,  NULL,    100),
('user_group_chat',         'User Group Chat',            'User-created group conversations',                 'messaging',     TRUE,  NULL,    100),
('message_media',           'Message Media',              'Send images, videos, audio in messages',           'messaging',     TRUE,  NULL,    100),
('message_reactions',       'Message Reactions',          'React to messages with emojis',                    'messaging',     TRUE,  NULL,    100),
('message_read_receipts',   'Read Receipts',              'Show when messages have been read',                'messaging',     TRUE,  NULL,    100),
('disappearing_messages',   'Disappearing Messages',      'Messages that auto-delete after a set time',       'messaging',     TRUE,  'basic', 100),
('message_threads',         'Message Threads',            'Reply to specific messages in a thread',           'messaging',     TRUE,  NULL,    100),
('voice_messages',          'Voice Messages',             'Send audio recordings in chat',                    'messaging',     TRUE,  NULL,    100),
('video_calls',             'Video Calls',                'In-app video calling between connections',         'messaging',     FALSE, 'pro',   0),
('audio_calls',             'Audio Calls',                'In-app audio calling between connections',         'messaging',     FALSE, 'basic', 0),

-- ── Content Features ─────────────────────────────────────────────────────────
('posts',                   'Posts',                      'Create and view posts in the main feed',           'content',       TRUE,  NULL,    100),
('post_photos',             'Post Photos',                'Attach photos to posts',                           'content',       TRUE,  NULL,    100),
('post_videos',             'Post Videos',                'Attach videos to posts',                           'content',       TRUE,  NULL,    100),
('post_comments',           'Post Comments',              'Comment on posts',                                 'content',       TRUE,  NULL,    100),
('post_likes',              'Post Likes',                 'Like posts',                                       'content',       TRUE,  NULL,    100),
('post_shares',             'Post Shares',                'Share posts to conversations or externally',       'content',       TRUE,  NULL,    100),
('post_saves',              'Post Saves',                 'Save posts to personal collection',                'content',       TRUE,  NULL,    100),
('stories',                 'Stories',                    'Post temporary 24-hour content',                   'content',       TRUE,  NULL,    100),
('story_polls',             'Story Polls',                'Add poll elements to stories',                     'content',       TRUE,  NULL,    100),
('story_questions',         'Story Questions',            'Add Q&A elements to stories',                      'content',       TRUE,  NULL,    100),
('reels',                   'Reels',                      'Short video content feed',                         'content',       TRUE,  NULL,    100),
('reel_upload',             'Reel Upload',                'Upload and publish short videos',                  'content',       TRUE,  NULL,    100),
('content_warnings',        'Content Warnings',           'Apply content warnings to posts',                  'content',       TRUE,  NULL,    100),
('hashtags',                'Hashtags',                   'Tag content with hashtags for discovery',          'content',       TRUE,  NULL,    100),

-- ── Discovery Features ─────────────────────────────────────────────────────────
('business_listings',       'Business Listings',          'View local business listings',                     'discovery',     TRUE,  NULL,    100),
('business_search',         'Business Search',            'Search businesses by name or category',            'discovery',     TRUE,  NULL,    100),
('polls',                   'Community Polls',            'Area-scoped polls visible to nearby users',        'discovery',     TRUE,  NULL,    100),
('events',                  'Events',                     'Create and discover local events',                 'discovery',     TRUE,  NULL,    100),
('marketplace',             'Marketplace',                'Buy and sell items with nearby users',             'discovery',     TRUE,  NULL,    100),
('explore_feed',            'Explore Feed',               'Discover content from beyond connections',         'discovery',     TRUE,  NULL,    100),

-- ── Monetization Features ──────────────────────────────────────────────────────
('premium_subscriptions',   'Premium Subscriptions',      'In-app subscription purchase flow',                'monetization',  TRUE,  NULL,    100),
('business_advertising',    'Business Advertising',       'Businesses can run ad campaigns',                  'monetization',  TRUE,  NULL,    100),
('boosted_posts',           'Boosted Posts',              'Users can boost their posts for visibility',       'monetization',  FALSE, 'basic', 0),
('analytics_dashboard',     'User Analytics',             'Personal analytics dashboard for users',           'monetization',  FALSE, 'pro',   0),

-- ── Admin & Experimental ──────────────────────────────────────────────────────
('admin_panel',             'Admin Panel',                'Backend admin dashboard access',                   'admin',         TRUE,  NULL,    100),
('admin_map_view',          'Admin Map View',             'Real-time map of active users in admin',           'admin',         TRUE,  NULL,    100),
('admin_content_moderation','Content Moderation Queue',   'Admin queue for reported content review',          'admin',         TRUE,  NULL,    100),
('push_notifications',      'Push Notifications',         'Send push notifications to devices',               'admin',         TRUE,  NULL,    100),
('ai_content_moderation',   'AI Content Moderation',      'Automatic AI-based content screening',             'experimental',  FALSE, NULL,    0),
('ai_matchmaking',          'AI Matchmaking',             'ML-based wave target suggestions',                 'experimental',  FALSE, NULL,    0),
('live_streaming',          'Live Streaming',             'Live video broadcast feature',                     'experimental',  FALSE, 'elite', 0)

ON CONFLICT (flag_key) DO UPDATE SET
    display_name        = EXCLUDED.display_name,
    description         = EXCLUDED.description,
    category            = EXCLUDED.category,
    required_tier       = EXCLUDED.required_tier,
    updated_at          = NOW();

-- Verify count
DO $$
DECLARE flag_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO flag_count FROM public.feature_flags;
    RAISE NOTICE 'Feature flags seeded: % total flags', flag_count;
END
$$;
