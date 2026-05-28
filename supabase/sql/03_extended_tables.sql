-- =====================================================
-- COLONY APP - EXTENDED TABLES (Tables 15-29)
-- =====================================================
-- This script creates tables for waves, connections,
-- stories, notifications, achievements, subscriptions,
-- and admin functionality.
-- =====================================================

-- =====================================================
-- TABLE 15: waves
-- =====================================================
-- Connection requests - "Wave" at someone nearby
-- Similar to a friend request but location-based
-- =====================================================

CREATE TABLE IF NOT EXISTS public.waves (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    receiver_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    wave_type TEXT DEFAULT 'friendly' CHECK (wave_type IN ('friendly', 'spark')),
    message TEXT CHECK (char_length(message) <= 100),
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'expired')),
    distance_at_wave DOUBLE PRECISION,
    created_at TIMESTAMPTZ DEFAULT now(),
    expires_at TIMESTAMPTZ DEFAULT (now() + interval '24 hours'),
    UNIQUE(sender_id, receiver_id)
);

COMMENT ON TABLE public.waves IS 'Connection requests - wave at nearby users to connect';

-- =====================================================
-- TABLE 16: connections
-- =====================================================
-- Accepted waves become connections/friends
-- Stores bidirectional relationships efficiently
-- =====================================================

CREATE TABLE IF NOT EXISTS public.connections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user1_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    user2_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    connected_at TIMESTAMPTZ DEFAULT now(),
    connection_source TEXT DEFAULT 'wave' CHECK (connection_source IN ('wave', 'group', 'event')),
    CHECK (user1_id < user2_id), -- Prevent duplicate pairs
    UNIQUE(user1_id, user2_id)
);

COMMENT ON TABLE public.connections IS 'Accepted connections between users - bidirectional friendships';

-- =====================================================
-- TABLE 17: stories
-- =====================================================
-- Ephemeral content that expires after 24 hours
-- Location-tagged visual content
-- =====================================================

CREATE TABLE IF NOT EXISTS public.stories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    media_url TEXT NOT NULL,
    media_type TEXT NOT NULL CHECK (media_type IN ('image', 'video')),
    thumbnail_url TEXT,
    caption TEXT CHECK (char_length(caption) <= 200),
    location_name TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    view_count INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    expires_at TIMESTAMPTZ DEFAULT (now() + interval '24 hours'),
    created_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.stories IS 'Ephemeral user stories - expire after 24 hours';

-- =====================================================
-- TABLE 18: story_views
-- =====================================================
-- Tracks who has viewed each story
-- Used for view counts and viewer lists
-- =====================================================

CREATE TABLE IF NOT EXISTS public.story_views (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    story_id UUID REFERENCES public.stories(id) ON DELETE CASCADE,
    viewer_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    viewed_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(story_id, viewer_id)
);

COMMENT ON TABLE public.story_views IS 'Story view tracking - who viewed which story';

-- =====================================================
-- TABLE 19: notifications
-- =====================================================
-- User notifications for various app events
-- Supports rich data payload via JSONB
-- =====================================================

CREATE TABLE IF NOT EXISTS public.notifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    type TEXT NOT NULL CHECK (type IN ('wave_received', 'wave_accepted', 'new_message', 'group_invite', 'event_nearby', 'event_reminder', 'new_connection', 'story_view', 'achievement_unlocked', 'system', 'admin')),
    title TEXT NOT NULL,
    body TEXT,
    data JSONB,
    is_read BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.notifications IS 'User notifications for app events and updates';

-- =====================================================
-- TABLE 20: achievements
-- =====================================================
-- Gamification achievements users can unlock
-- Rewards karma points for milestones
-- =====================================================

CREATE TABLE IF NOT EXISTS public.achievements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    description TEXT NOT NULL,
    icon_url TEXT,
    badge_color TEXT,
    karma_reward INTEGER DEFAULT 0,
    category TEXT CHECK (category IN ('social', 'explorer', 'host', 'community', 'special')),
    requirement_count INTEGER DEFAULT 1,
    is_active BOOLEAN DEFAULT true
);

COMMENT ON TABLE public.achievements IS 'Achievement definitions - gamification milestones';

-- =====================================================
-- TABLE 21: user_achievements
-- =====================================================
-- User progress towards achievements
-- Tracks completion status
-- =====================================================

CREATE TABLE IF NOT EXISTS public.user_achievements (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    achievement_id UUID REFERENCES public.achievements(id) ON DELETE CASCADE,
    progress INTEGER DEFAULT 0,
    is_completed BOOLEAN DEFAULT false,
    completed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(user_id, achievement_id)
);

COMMENT ON TABLE public.user_achievements IS 'User progress on achievements';

-- =====================================================
-- TABLE 22: daily_streaks
-- =====================================================
-- Tracks user activity streaks
-- Rewards consistent app usage
-- =====================================================

CREATE TABLE IF NOT EXISTS public.daily_streaks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    streak_type TEXT NOT NULL CHECK (streak_type IN ('app_open', 'wave_sent', 'chat_active', 'story_posted')),
    current_streak INTEGER DEFAULT 0,
    longest_streak INTEGER DEFAULT 0,
    last_activity_date DATE,
    UNIQUE(user_id, streak_type)
);

COMMENT ON TABLE public.daily_streaks IS 'User activity streaks for gamification';

-- =====================================================
-- TABLE 23: user_subscriptions
-- =====================================================
-- Premium subscription management
-- Tracks payment and expiry
-- =====================================================

CREATE TABLE IF NOT EXISTS public.user_subscriptions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    plan_type TEXT NOT NULL CHECK (plan_type IN ('monthly', 'yearly')),
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'cancelled', 'expired')),
    amount DECIMAL(10,2),
    currency TEXT DEFAULT 'INR',
    started_at TIMESTAMPTZ DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    payment_id TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.user_subscriptions IS 'Premium subscription records for monetization';

-- =====================================================
-- TABLE 24: profile_boosts
-- =====================================================
-- Temporary profile visibility boosts
-- Premium feature for increased visibility
-- =====================================================

CREATE TABLE IF NOT EXISTS public.profile_boosts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    boost_type TEXT DEFAULT 'standard' CHECK (boost_type IN ('standard', 'super')),
    started_at TIMESTAMPTZ DEFAULT now(),
    expires_at TIMESTAMPTZ NOT NULL,
    is_active BOOLEAN DEFAULT true
);

COMMENT ON TABLE public.profile_boosts IS 'Profile visibility boosts - premium feature';

-- =====================================================
-- TABLE 25: virtual_gifts
-- =====================================================
-- Virtual gifts users can send each other
-- Monetization through in-app purchases
-- =====================================================

CREATE TABLE IF NOT EXISTS public.virtual_gifts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    receiver_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    gift_type TEXT NOT NULL,
    gift_name TEXT NOT NULL,
    gift_icon_url TEXT,
    price DECIMAL(10,2),
    message TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.virtual_gifts IS 'Virtual gifts sent between users';

-- =====================================================
-- TABLE 26: admin_settings
-- =====================================================
-- Dynamic app configuration
-- Key-value store with JSONB values
-- =====================================================

CREATE TABLE IF NOT EXISTS public.admin_settings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key TEXT UNIQUE NOT NULL,
    value JSONB NOT NULL,
    description TEXT,
    updated_at TIMESTAMPTZ DEFAULT now(),
    updated_by UUID REFERENCES public.profiles(id)
);

COMMENT ON TABLE public.admin_settings IS 'Dynamic app configuration settings';

-- =====================================================
-- TABLE 27: admin_audit_log
-- =====================================================
-- Audit trail for admin actions
-- Tracks all moderation and configuration changes
-- =====================================================

CREATE TABLE IF NOT EXISTS public.admin_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    admin_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    action TEXT NOT NULL,
    target_type TEXT CHECK (target_type IN ('user', 'group', 'event', 'message', 'report', 'setting')),
    target_id UUID,
    details JSONB,
    created_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.admin_audit_log IS 'Audit trail for admin actions';

-- =====================================================
-- TABLE 28: polls
-- =====================================================
-- Location-based polls for community engagement
-- Can be group-specific or public
-- =====================================================

CREATE TABLE IF NOT EXISTS public.polls (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    question TEXT NOT NULL,
    options JSONB NOT NULL, -- Array of option objects: [{"text": "Option 1", "votes": 0}, ...]
    created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    group_id UUID REFERENCES public.groups(id) ON DELETE CASCADE,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    radius_km DOUBLE PRECISION DEFAULT 5.0,
    expires_at TIMESTAMPTZ,
    total_votes INTEGER DEFAULT 0,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.polls IS 'Location-based community polls';

-- =====================================================
-- TABLE 29: poll_votes
-- =====================================================
-- Individual votes on polls
-- One vote per user per poll
-- =====================================================

CREATE TABLE IF NOT EXISTS public.poll_votes (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    poll_id UUID REFERENCES public.polls(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    option_index INTEGER NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(poll_id, user_id)
);

COMMENT ON TABLE public.poll_votes IS 'Individual poll votes';

-- =====================================================
-- INDEXES FOR EXTENDED TABLES
-- =====================================================

-- Waves indexes
CREATE INDEX IF NOT EXISTS idx_waves_receiver_status ON public.waves(receiver_id, status);
CREATE INDEX IF NOT EXISTS idx_waves_sender ON public.waves(sender_id);

-- Connections indexes
CREATE INDEX IF NOT EXISTS idx_connections_user1 ON public.connections(user1_id);
CREATE INDEX IF NOT EXISTS idx_connections_user2 ON public.connections(user2_id);

-- Stories indexes
CREATE INDEX IF NOT EXISTS idx_stories_user_active_expires ON public.stories(user_id, is_active, expires_at);

-- Notifications indexes
CREATE INDEX IF NOT EXISTS idx_notifications_user_read ON public.notifications(user_id, is_read);

-- User achievements index
CREATE INDEX IF NOT EXISTS idx_user_achievements_user ON public.user_achievements(user_id);

-- Profile boosts index
CREATE INDEX IF NOT EXISTS idx_profile_boosts_user_active ON public.profile_boosts(user_id, is_active);

-- =====================================================
-- DEFAULT ACHIEVEMENTS DATA
-- =====================================================

INSERT INTO public.achievements (code, name, description, karma_reward, category, requirement_count) VALUES
('first_wave', 'First Wave', 'Send your first wave to someone nearby', 10, 'social', 1),
('wave_master_10', 'Wave Master', 'Send 10 waves', 25, 'social', 10),
('social_butterfly_50', 'Social Butterfly', 'Make 50 connections', 100, 'social', 50),
('event_host_1', 'Party Starter', 'Host your first event', 50, 'host', 1),
('event_host_5', 'Event Mogul', 'Host 5 events', 150, 'host', 5),
('group_creator', 'Hive Builder', 'Create your first group', 30, 'community', 1),
('story_teller_10', 'Story Teller', 'Post 10 stories', 20, 'social', 10),
('streak_7', 'Week Warrior', '7-day app streak', 50, 'explorer', 7),
('streak_30', 'Monthly Legend', '30-day app streak', 200, 'explorer', 30),
('colony_pioneer', 'Colony Pioneer', 'Be among the first 100 users', 500, 'special', 1),
('night_owl', 'Night Owl', 'Active after midnight 10 times', 30, 'special', 10),
('early_bird', 'Early Bird', 'Active before 6 AM 10 times', 30, 'special', 10);

-- =====================================================
-- DEFAULT ADMIN SETTINGS DATA
-- =====================================================

INSERT INTO public.admin_settings (key, value, description) VALUES
('max_wave_per_day', '{"free": 10, "premium": 999}', 'Maximum waves per day'),
('nearby_radius_km', '{"free": 5, "premium": 10}', 'Nearby discovery radius'),
('max_group_members', '{"free": 200, "premium": 500}', 'Max members per group'),
('story_duration_hours', '{"value": 24}', 'Story visibility duration'),
('wave_expiry_hours', '{"value": 24}', 'Wave expiry time'),
('max_accounts_per_device', '{"value": 2}', 'Max accounts per device'),
('min_age', '{"value": 16}', 'Minimum age to use app'),
('maintenance_mode', '{"enabled": false, "message": ""}', 'App maintenance mode');

-- =====================================================
-- END OF EXTENDED TABLES SCRIPT
-- =====================================================
