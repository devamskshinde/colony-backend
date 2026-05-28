-- =====================================================
-- COLONY APP - CORE TABLES (Tables 1-5)
-- =====================================================
-- This script creates the foundational tables for the
-- Colony location-based social community app.
-- =====================================================

-- =====================================================
-- TABLE 1: profiles
-- =====================================================
-- Main user profile table, extends auth.users
-- Contains all user information including location,
-- preferences, verification status, and premium features
-- =====================================================

CREATE TABLE IF NOT EXISTS public.profiles (
    id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    phone TEXT UNIQUE,
    username TEXT UNIQUE NOT NULL,
    full_name TEXT NOT NULL,
    bio TEXT CHECK (char_length(bio) <= 500),
    avatar_url TEXT,
    date_of_birth DATE,
    gender TEXT CHECK (gender IN ('male', 'female', 'non-binary', 'prefer_not_to_say')),
    looking_for TEXT[] DEFAULT ARRAY[]::TEXT[],
    interests TEXT[] DEFAULT ARRAY[]::TEXT[],
    profession TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    location_name TEXT,
    last_location_update TIMESTAMPTZ,
    is_online BOOLEAN DEFAULT false,
    last_seen TIMESTAMPTZ,
    is_verified BOOLEAN DEFAULT false,
    is_premium BOOLEAN DEFAULT false,
    premium_expires_at TIMESTAMPTZ,
    colony_level INTEGER DEFAULT 1,
    karma_points INTEGER DEFAULT 0,
    device_id TEXT,
    device_model TEXT,
    fcm_token TEXT,
    is_banned BOOLEAN DEFAULT false,
    ban_reason TEXT,
    ghost_mode BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Add comment to profiles table
COMMENT ON TABLE public.profiles IS 'User profiles extending auth.users with location, preferences, and social data';

-- =====================================================
-- TABLE 2: device_logs
-- =====================================================
-- Tracks device login history for security and
-- device limit enforcement
-- =====================================================

CREATE TABLE IF NOT EXISTS public.device_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    device_model TEXT,
    os_version TEXT,
    app_version TEXT,
    ip_address TEXT,
    login_at TIMESTAMPTZ DEFAULT now(),
    is_active BOOLEAN DEFAULT true
);

COMMENT ON TABLE public.device_logs IS 'Tracks user device logins for security and multi-account detection';

-- =====================================================
-- TABLE 3: blocked_devices
-- =====================================================
-- Admin-managed list of banned devices
-- Prevents banned users from creating new accounts
-- =====================================================

CREATE TABLE IF NOT EXISTS public.blocked_devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id TEXT UNIQUE NOT NULL,
    reason TEXT,
    blocked_by UUID REFERENCES public.profiles(id),
    blocked_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.blocked_devices IS 'Admin-managed blocked devices to prevent banned users from rejoining';

-- =====================================================
-- TABLE 4: user_reports
-- =====================================================
-- User-generated reports for moderation
-- Tracks spam, harassment, fake profiles, etc.
-- =====================================================

CREATE TABLE IF NOT EXISTS public.user_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    reported_user_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    reason TEXT NOT NULL CHECK (reason IN ('spam', 'harassment', 'fake_profile', 'inappropriate_content', 'other')),
    description TEXT,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'action_taken', 'dismissed')),
    admin_notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.user_reports IS 'User reports for moderation - spam, harassment, fake profiles, etc.';

-- =====================================================
-- TABLE 5: blocked_users
-- =====================================================
-- User-level blocking for privacy
-- Blocked users cannot see each other's profiles
-- =====================================================

CREATE TABLE IF NOT EXISTS public.blocked_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    blocker_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    blocked_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(blocker_id, blocked_id)
);

COMMENT ON TABLE public.blocked_users IS 'User-level blocking - blocked users cannot interact or see each other';

-- =====================================================
-- INDEXES FOR CORE TABLES
-- =====================================================

-- Profiles table indexes for location-based queries
CREATE INDEX IF NOT EXISTS idx_profiles_location ON public.profiles(latitude, longitude);
CREATE INDEX IF NOT EXISTS idx_profiles_is_online ON public.profiles(is_online);
CREATE INDEX IF NOT EXISTS idx_profiles_username ON public.profiles(username);

-- Device logs indexes for device tracking
CREATE INDEX IF NOT EXISTS idx_device_logs_device_id ON public.device_logs(device_id);
CREATE INDEX IF NOT EXISTS idx_device_logs_user_id ON public.device_logs(user_id);

-- =====================================================
-- UPDATED_AT TRIGGER FUNCTION
-- =====================================================
-- Auto-updates updated_at column on row modification
-- =====================================================

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.update_updated_at_column() IS 'Trigger function to auto-update updated_at timestamp';

-- Apply trigger to profiles table
CREATE TRIGGER update_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

-- =====================================================
-- DEVICE LIMIT CONSTRAINT
-- =====================================================
-- Prevents more than 3 user accounts per device
-- Uses a trigger to enforce the constraint
-- =====================================================

CREATE OR REPLACE FUNCTION public.check_device_limit_trigger()
RETURNS TRIGGER AS $$
DECLARE
    device_user_count INTEGER;
    max_accounts INTEGER := 3;
BEGIN
    -- Count distinct users for this device
    SELECT COUNT(DISTINCT user_id) INTO device_user_count
    FROM public.device_logs
    WHERE device_id = NEW.device_id AND is_active = true;
    
    -- Check if adding this user would exceed the limit
    IF device_user_count >= max_accounts THEN
        -- Check if this user is already linked to this device
        IF NOT EXISTS (
            SELECT 1 FROM public.device_logs 
            WHERE device_id = NEW.device_id AND user_id = NEW.user_id
        ) THEN
            RAISE EXCEPTION 'Device limit reached: This device is already linked to % user accounts', device_user_count;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.check_device_limit_trigger() IS 'Enforces maximum accounts per device limit';

-- Apply device limit trigger
CREATE TRIGGER enforce_device_limit
    BEFORE INSERT ON public.device_logs
    FOR EACH ROW
    EXECUTE FUNCTION public.check_device_limit_trigger();

-- =====================================================
-- END OF CORE TABLES SCRIPT
-- =====================================================
-- =====================================================
-- COLONY APP - SOCIAL TABLES (Tables 6-14)
-- =====================================================
-- This script creates tables for messaging, groups,
-- and events functionality.
-- =====================================================

-- =====================================================
-- TABLE 6: conversations
-- =====================================================
-- Stores conversation threads (direct and group)
-- Direct messages have null group_id
-- =====================================================

CREATE TABLE IF NOT EXISTS public.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type TEXT NOT NULL CHECK (type IN ('direct', 'group')),
    group_id UUID, -- Will reference groups table (added later)
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.conversations IS 'Conversation threads - direct messages or group chats';

-- =====================================================
-- TABLE 7: conversation_participants
-- =====================================================
-- Links users to conversations with their roles
-- Tracks read status and notification preferences
-- =====================================================

CREATE TABLE IF NOT EXISTS public.conversation_participants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID REFERENCES public.conversations(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    role TEXT DEFAULT 'member' CHECK (role IN ('member', 'admin', 'owner')),
    joined_at TIMESTAMPTZ DEFAULT now(),
    last_read_at TIMESTAMPTZ,
    is_muted BOOLEAN DEFAULT false,
    is_pinned BOOLEAN DEFAULT false,
    UNIQUE(conversation_id, user_id)
);

COMMENT ON TABLE public.conversation_participants IS 'Users participating in conversations with roles and preferences';

-- =====================================================
-- TABLE 8: messages
-- =====================================================
-- Individual messages within conversations
-- Supports various media types and replies
-- =====================================================

CREATE TABLE IF NOT EXISTS public.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID REFERENCES public.conversations(id) ON DELETE CASCADE,
    sender_id UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    content TEXT,
    message_type TEXT DEFAULT 'text' CHECK (message_type IN ('text', 'image', 'video', 'audio', 'gif', 'sticker', 'voice_note', 'location', 'event_share')),
    media_url TEXT,
    thumbnail_url TEXT,
    reply_to_id UUID REFERENCES public.messages(id) ON DELETE SET NULL,
    is_deleted BOOLEAN DEFAULT false,
    is_edited BOOLEAN DEFAULT false,
    edited_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.messages IS 'Messages in conversations - supports text, media, and various content types';

-- =====================================================
-- TABLE 9: message_reactions
-- =====================================================
-- Emoji reactions to messages
-- One reaction per user per message per emoji
-- =====================================================

CREATE TABLE IF NOT EXISTS public.message_reactions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID REFERENCES public.messages(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    emoji TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(message_id, user_id, emoji)
);

COMMENT ON TABLE public.message_reactions IS 'Emoji reactions on messages';

-- =====================================================
-- TABLE 10: message_read_receipts
-- =====================================================
-- Tracks who has read each message
-- Used for read indicators in chat
-- =====================================================

CREATE TABLE IF NOT EXISTS public.message_read_receipts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID REFERENCES public.messages(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    read_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(message_id, user_id)
);

COMMENT ON TABLE public.message_read_receipts IS 'Read receipts for messages - tracks who read what';

-- =====================================================
-- TABLE 11: groups
-- =====================================================
-- Location-based community groups
-- Users can create and join groups within radius
-- =====================================================

CREATE TABLE IF NOT EXISTS public.groups (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    cover_image_url TEXT,
    icon_url TEXT,
    category TEXT NOT NULL CHECK (category IN ('tech', 'fitness', 'lifestyle', 'art_design', 'music', 'food', 'sports', 'education', 'gaming', 'other')),
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    location_name TEXT,
    radius_km DOUBLE PRECISION DEFAULT 5.0,
    max_members INTEGER DEFAULT 200,
    member_count INTEGER DEFAULT 0,
    is_private BOOLEAN DEFAULT false,
    join_approval_required BOOLEAN DEFAULT false,
    created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    is_premium_group BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.groups IS 'Location-based community groups with categories and membership';

-- Add foreign key from conversations to groups
ALTER TABLE public.conversations 
ADD CONSTRAINT fk_conversations_group_id 
FOREIGN KEY (group_id) REFERENCES public.groups(id) ON DELETE CASCADE;

-- =====================================================
-- TABLE 12: group_members
-- =====================================================
-- Membership and roles within groups
-- Tracks join date and status
-- =====================================================

CREATE TABLE IF NOT EXISTS public.group_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID REFERENCES public.groups(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    role TEXT DEFAULT 'member' CHECK (role IN ('member', 'moderator', 'admin', 'owner')),
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'pending', 'banned')),
    joined_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(group_id, user_id)
);

COMMENT ON TABLE public.group_members IS 'Group membership with roles and status';

-- =====================================================
-- TABLE 13: events
-- =====================================================
-- Location-based events (house parties, meetups, etc.)
-- Can be standalone or group events
-- =====================================================

CREATE TABLE IF NOT EXISTS public.events (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title TEXT NOT NULL,
    description TEXT,
    cover_image_url TEXT,
    event_type TEXT NOT NULL CHECK (event_type IN ('house_party', 'meetup', 'workshop', 'sports', 'food', 'music', 'community', 'other')),
    latitude DOUBLE PRECISION NOT NULL,
    longitude DOUBLE PRECISION NOT NULL,
    location_name TEXT,
    address TEXT,
    starts_at TIMESTAMPTZ NOT NULL,
    ends_at TIMESTAMPTZ,
    max_attendees INTEGER,
    current_attendees INTEGER DEFAULT 0,
    is_free BOOLEAN DEFAULT true,
    price DECIMAL(10,2),
    created_by UUID REFERENCES public.profiles(id) ON DELETE SET NULL,
    group_id UUID REFERENCES public.groups(id) ON DELETE SET NULL, -- Can be group event or personal
    broadcast_radius_km DOUBLE PRECISION DEFAULT 5.0,
    is_promoted BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

COMMENT ON TABLE public.events IS 'Location-based events - can be standalone or group events';

-- =====================================================
-- TABLE 14: event_responses
-- =====================================================
-- User responses to events (going, interested, not_going)
-- =====================================================

CREATE TABLE IF NOT EXISTS public.event_responses (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_id UUID REFERENCES public.events(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK (status IN ('going', 'interested', 'not_going')),
    responded_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(event_id, user_id)
);

COMMENT ON TABLE public.event_responses IS 'User responses to events - going, interested, or not going';

-- =====================================================
-- INDEXES FOR SOCIAL TABLES
-- =====================================================

-- Messages indexes for efficient querying
CREATE INDEX IF NOT EXISTS idx_messages_conversation_created ON public.messages(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON public.messages(sender_id);

-- Groups indexes for location and category queries
CREATE INDEX IF NOT EXISTS idx_groups_location ON public.groups(latitude, longitude);
CREATE INDEX IF NOT EXISTS idx_groups_category ON public.groups(category);

-- Events indexes for location and time queries
CREATE INDEX IF NOT EXISTS idx_events_location ON public.events(latitude, longitude);
CREATE INDEX IF NOT EXISTS idx_events_starts_at ON public.events(starts_at);
CREATE INDEX IF NOT EXISTS idx_events_created_by ON public.events(created_by);

-- Group members index for user's groups
CREATE INDEX IF NOT EXISTS idx_group_members_user ON public.group_members(user_id);

-- Conversation participants index for user's conversations
CREATE INDEX IF NOT EXISTS idx_conversation_participants_user ON public.conversation_participants(user_id);

-- =====================================================
-- UPDATED_AT TRIGGERS FOR SOCIAL TABLES
-- =====================================================

-- Conversations updated_at trigger
CREATE TRIGGER update_conversations_updated_at
    BEFORE UPDATE ON public.conversations
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

-- Groups updated_at trigger
CREATE TRIGGER update_groups_updated_at
    BEFORE UPDATE ON public.groups
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

-- Events updated_at trigger
CREATE TRIGGER update_events_updated_at
    BEFORE UPDATE ON public.events
    FOR EACH ROW
    EXECUTE FUNCTION public.update_updated_at_column();

-- =====================================================
-- END OF SOCIAL TABLES SCRIPT
-- =====================================================
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
-- =====================================================
-- COLONY APP - ROW LEVEL SECURITY POLICIES
-- =====================================================
-- This script enables RLS on all tables and creates
-- comprehensive security policies for data access.
-- =====================================================

-- =====================================================
-- HELPER FUNCTIONS FOR RLS
-- =====================================================

-- Function to check if a user is an admin
CREATE OR REPLACE FUNCTION public.is_admin(user_id UUID)
RETURNS BOOLEAN AS $$
BEGIN
    -- Check if user has admin role in any group they're part of
    -- Or if they have a special admin flag (we can add an is_admin column to profiles later)
    -- For now, we'll check if they're an owner of any group
    RETURN EXISTS (
        SELECT 1 FROM public.group_members 
        WHERE user_id = is_admin.user_id 
        AND role = 'owner'
    ) OR EXISTS (
        SELECT 1 FROM public.profiles 
        WHERE id = is_admin.user_id 
        AND is_banned = false
        AND is_premium = true
        -- Add additional admin check here when is_admin column is added
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.is_admin(UUID) IS 'Checks if user has admin privileges';

-- Function to check if two users have blocked each other
CREATE OR REPLACE FUNCTION public.are_users_blocked(uid1 UUID, uid2 UUID)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN EXISTS (
        SELECT 1 FROM public.blocked_users
        WHERE (blocker_id = uid1 AND blocked_id = uid2)
           OR (blocker_id = uid2 AND blocked_id = uid1)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.are_users_blocked(UUID, UUID) IS 'Checks if two users have blocked each other';

-- =====================================================
-- ENABLE RLS ON ALL TABLES
-- =====================================================

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blocked_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.blocked_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversation_participants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_reactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.message_read_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.event_responses ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.waves ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.story_views ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_achievements ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.daily_streaks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.user_subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.profile_boosts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.virtual_gifts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_audit_log ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.polls ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.poll_votes ENABLE ROW LEVEL SECURITY;

-- =====================================================
-- PROFILES TABLE POLICIES
-- =====================================================

-- SELECT: Anyone authenticated can read any profile (except blocked users)
CREATE POLICY "profiles_select_policy" ON public.profiles
    FOR SELECT USING (
        auth.uid() IS NOT NULL
        AND NOT public.are_users_blocked(auth.uid(), id)
        AND is_banned = false
    );

-- INSERT: Users can insert their own profile
CREATE POLICY "profiles_insert_policy" ON public.profiles
    FOR INSERT WITH CHECK (auth.uid() = id);

-- UPDATE: Users can only update their own profile
CREATE POLICY "profiles_update_policy" ON public.profiles
    FOR UPDATE USING (auth.uid() = id);

-- DELETE: No direct deletes (admin uses service role)
-- No DELETE policy = no one can delete

-- =====================================================
-- DEVICE_LOGS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see their own device logs only
CREATE POLICY "device_logs_select_policy" ON public.device_logs
    FOR SELECT USING (auth.uid() = user_id);

-- INSERT: Users can insert their own logs
CREATE POLICY "device_logs_insert_policy" ON public.device_logs
    FOR INSERT WITH CHECK (auth.uid() = user_id);

-- No UPDATE or DELETE for users

-- =====================================================
-- BLOCKED_DEVICES TABLE POLICIES
-- =====================================================

-- Admin only access
CREATE POLICY "blocked_devices_admin_select" ON public.blocked_devices
    FOR SELECT USING (public.is_admin(auth.uid()));

CREATE POLICY "blocked_devices_admin_insert" ON public.blocked_devices
    FOR INSERT WITH CHECK (public.is_admin(auth.uid()));

CREATE POLICY "blocked_devices_admin_update" ON public.blocked_devices
    FOR UPDATE USING (public.is_admin(auth.uid()));

-- =====================================================
-- USER_REPORTS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see their own reports
CREATE POLICY "user_reports_select_policy" ON public.user_reports
    FOR SELECT USING (
        reporter_id = auth.uid() 
        OR public.is_admin(auth.uid())
    );

-- INSERT: Users can create reports
CREATE POLICY "user_reports_insert_policy" ON public.user_reports
    FOR INSERT WITH CHECK (reporter_id = auth.uid());

-- UPDATE: Admin only
CREATE POLICY "user_reports_update_policy" ON public.user_reports
    FOR UPDATE USING (public.is_admin(auth.uid()));

-- =====================================================
-- BLOCKED_USERS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see their own blocks
CREATE POLICY "blocked_users_select_policy" ON public.blocked_users
    FOR SELECT USING (blocker_id = auth.uid() OR blocked_id = auth.uid());

-- INSERT: Users can block anyone
CREATE POLICY "blocked_users_insert_policy" ON public.blocked_users
    FOR INSERT WITH CHECK (blocker_id = auth.uid());

-- DELETE: Users can unblock (blocker_id must match)
CREATE POLICY "blocked_users_delete_policy" ON public.blocked_users
    FOR DELETE USING (blocker_id = auth.uid());

-- =====================================================
-- CONVERSATIONS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see conversations they participate in
CREATE POLICY "conversations_select_policy" ON public.conversations
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.conversation_participants
            WHERE conversation_id = conversations.id
            AND user_id = auth.uid()
        )
    );

-- INSERT: For direct chats, authenticated users can create
CREATE POLICY "conversations_insert_policy" ON public.conversations
    FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- UPDATE: Participants can update
CREATE POLICY "conversations_update_policy" ON public.conversations
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM public.conversation_participants
            WHERE conversation_id = conversations.id
            AND user_id = auth.uid()
        )
    );

-- =====================================================
-- CONVERSATION_PARTICIPANTS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see participants of their conversations
CREATE POLICY "conversation_participants_select_policy" ON public.conversation_participants
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.conversation_participants cp
            WHERE cp.conversation_id = conversation_participants.conversation_id
            AND cp.user_id = auth.uid()
        )
    );

-- INSERT: For direct chats, authenticated users
CREATE POLICY "conversation_participants_insert_policy" ON public.conversation_participants
    FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- UPDATE: Users can update their own participation
CREATE POLICY "conversation_participants_update_policy" ON public.conversation_participants
    FOR UPDATE USING (user_id = auth.uid());

-- =====================================================
-- MESSAGES TABLE POLICIES
-- =====================================================

-- SELECT: Users can read messages in their conversations
CREATE POLICY "messages_select_policy" ON public.messages
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.conversation_participants
            WHERE conversation_id = messages.conversation_id
            AND user_id = auth.uid()
        )
    );

-- INSERT: Users can send messages in their conversations
CREATE POLICY "messages_insert_policy" ON public.messages
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.conversation_participants
            WHERE conversation_id = messages.conversation_id
            AND user_id = auth.uid()
        )
    );

-- UPDATE: Users can edit their own messages
CREATE POLICY "messages_update_policy" ON public.messages
    FOR UPDATE USING (sender_id = auth.uid());

-- DELETE: Users can soft-delete their own messages
CREATE POLICY "messages_delete_policy" ON public.messages
    FOR DELETE USING (sender_id = auth.uid());

-- =====================================================
-- MESSAGE_REACTIONS TABLE POLICIES
-- =====================================================

-- SELECT: Anyone in the conversation can see reactions
CREATE POLICY "message_reactions_select_policy" ON public.message_reactions
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.conversation_participants cp
            JOIN public.messages m ON m.id = message_reactions.message_id
            WHERE cp.conversation_id = m.conversation_id
            AND cp.user_id = auth.uid()
        )
    );

-- INSERT: Users can add reactions to messages in their conversations
CREATE POLICY "message_reactions_insert_policy" ON public.message_reactions
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.conversation_participants cp
            JOIN public.messages m ON m.id = message_reactions.message_id
            WHERE cp.conversation_id = m.conversation_id
            AND cp.user_id = auth.uid()
        )
    );

-- DELETE: Users can remove their own reactions
CREATE POLICY "message_reactions_delete_policy" ON public.message_reactions
    FOR DELETE USING (user_id = auth.uid());

-- =====================================================
-- MESSAGE_READ_RECEIPTS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see receipts for their messages or their own receipts
CREATE POLICY "message_read_receipts_select_policy" ON public.message_read_receipts
    FOR SELECT USING (
        user_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.messages m
            WHERE m.id = message_read_receipts.message_id
            AND m.sender_id = auth.uid()
        )
    );

-- INSERT: Users can record their own views
CREATE POLICY "message_read_receipts_insert_policy" ON public.message_read_receipts
    FOR INSERT WITH CHECK (user_id = auth.uid());

-- =====================================================
-- GROUPS TABLE POLICIES
-- =====================================================

-- SELECT: Anyone authenticated can see active groups
CREATE POLICY "groups_select_policy" ON public.groups
    FOR SELECT USING (
        auth.uid() IS NOT NULL
        AND is_active = true
    );

-- INSERT: Authenticated users can create groups
CREATE POLICY "groups_insert_policy" ON public.groups
    FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- UPDATE: Only group owner/admin can update
CREATE POLICY "groups_update_policy" ON public.groups
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM public.group_members
            WHERE group_id = groups.id
            AND user_id = auth.uid()
            AND role IN ('owner', 'admin')
        )
    );

-- DELETE: Only group owner can delete
CREATE POLICY "groups_delete_policy" ON public.groups
    FOR DELETE USING (
        EXISTS (
            SELECT 1 FROM public.group_members
            WHERE group_id = groups.id
            AND user_id = auth.uid()
            AND role = 'owner'
        )
    );

-- =====================================================
-- GROUP_MEMBERS TABLE POLICIES
-- =====================================================

-- SELECT: Anyone can see group members of groups they're in
CREATE POLICY "group_members_select_policy" ON public.group_members
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM public.group_members gm
            WHERE gm.group_id = group_members.group_id
            AND gm.user_id = auth.uid()
        )
    );

-- INSERT: Users can join groups or be added
CREATE POLICY "group_members_insert_policy" ON public.group_members
    FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- UPDATE: Group admin/owner can change roles
CREATE POLICY "group_members_update_policy" ON public.group_members
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM public.group_members gm
            WHERE gm.group_id = group_members.group_id
            AND gm.user_id = auth.uid()
            AND gm.role IN ('owner', 'admin')
        )
    );

-- DELETE: Users can leave; admins can remove
CREATE POLICY "group_members_delete_policy" ON public.group_members
    FOR DELETE USING (
        user_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.group_members gm
            WHERE gm.group_id = group_members.group_id
            AND gm.user_id = auth.uid()
            AND gm.role IN ('owner', 'admin')
        )
    );

-- =====================================================
-- EVENTS TABLE POLICIES
-- =====================================================

-- SELECT: Authenticated users can see active events
CREATE POLICY "events_select_policy" ON public.events
    FOR SELECT USING (
        auth.uid() IS NOT NULL
        AND is_active = true
    );

-- INSERT: Authenticated users can create events
CREATE POLICY "events_insert_policy" ON public.events
    FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- UPDATE: Event creator can update
CREATE POLICY "events_update_policy" ON public.events
    FOR UPDATE USING (created_by = auth.uid());

-- DELETE: Event creator can delete
CREATE POLICY "events_delete_policy" ON public.events
    FOR DELETE USING (created_by = auth.uid());

-- =====================================================
-- EVENT_RESPONSES TABLE POLICIES
-- =====================================================

-- SELECT: Anyone can see responses for events they can see
CREATE POLICY "event_responses_select_policy" ON public.event_responses
    FOR SELECT USING (auth.uid() IS NOT NULL);

-- INSERT: Users can respond to events
CREATE POLICY "event_responses_insert_policy" ON public.event_responses
    FOR INSERT WITH CHECK (user_id = auth.uid());

-- UPDATE: Users can change their response
CREATE POLICY "event_responses_update_policy" ON public.event_responses
    FOR UPDATE USING (user_id = auth.uid());

-- DELETE: Users can remove their response
CREATE POLICY "event_responses_delete_policy" ON public.event_responses
    FOR DELETE USING (user_id = auth.uid());

-- =====================================================
-- WAVES TABLE POLICIES
-- =====================================================

-- SELECT: Users can see waves they sent OR received
CREATE POLICY "waves_select_policy" ON public.waves
    FOR SELECT USING (sender_id = auth.uid() OR receiver_id = auth.uid());

-- INSERT: Users can send waves
CREATE POLICY "waves_insert_policy" ON public.waves
    FOR INSERT WITH CHECK (sender_id = auth.uid());

-- UPDATE: Receiver can accept/decline
CREATE POLICY "waves_update_policy" ON public.waves
    FOR UPDATE USING (receiver_id = auth.uid());

-- =====================================================
-- CONNECTIONS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see their own connections
CREATE POLICY "connections_select_policy" ON public.connections
    FOR SELECT USING (user1_id = auth.uid() OR user2_id = auth.uid());

-- INSERT: System-managed (through functions)
-- No direct insert policy - use accept_wave function

-- DELETE: Either connected user can delete
CREATE POLICY "connections_delete_policy" ON public.connections
    FOR DELETE USING (user1_id = auth.uid() OR user2_id = auth.uid());

-- =====================================================
-- STORIES TABLE POLICIES
-- =====================================================

-- SELECT: Authenticated users can see active, non-expired stories (not from blocked users)
CREATE POLICY "stories_select_policy" ON public.stories
    FOR SELECT USING (
        auth.uid() IS NOT NULL
        AND is_active = true
        AND expires_at > now()
        AND NOT public.are_users_blocked(auth.uid(), user_id)
    );

-- INSERT: Users can create their own stories
CREATE POLICY "stories_insert_policy" ON public.stories
    FOR INSERT WITH CHECK (user_id = auth.uid());

-- UPDATE: Users can update their own stories
CREATE POLICY "stories_update_policy" ON public.stories
    FOR UPDATE USING (user_id = auth.uid());

-- DELETE: Users can delete their own stories
CREATE POLICY "stories_delete_policy" ON public.stories
    FOR DELETE USING (user_id = auth.uid());

-- =====================================================
-- STORY_VIEWS TABLE POLICIES
-- =====================================================

-- SELECT: Story owner can see who viewed; viewer can see their own views
CREATE POLICY "story_views_select_policy" ON public.story_views
    FOR SELECT USING (
        viewer_id = auth.uid()
        OR EXISTS (
            SELECT 1 FROM public.stories
            WHERE stories.id = story_views.story_id
            AND stories.user_id = auth.uid()
        )
    );

-- INSERT: Users can record their own views
CREATE POLICY "story_views_insert_policy" ON public.story_views
    FOR INSERT WITH CHECK (viewer_id = auth.uid());

-- =====================================================
-- NOTIFICATIONS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see their own notifications only
CREATE POLICY "notifications_select_policy" ON public.notifications
    FOR SELECT USING (user_id = auth.uid());

-- INSERT: System-managed
-- No direct insert policy - use notification functions

-- UPDATE: Users can mark their own as read
CREATE POLICY "notifications_update_policy" ON public.notifications
    FOR UPDATE USING (user_id = auth.uid());

-- =====================================================
-- ACHIEVEMENTS TABLE POLICIES
-- =====================================================

-- SELECT: Anyone can see achievements
CREATE POLICY "achievements_select_policy" ON public.achievements
    FOR SELECT USING (auth.uid() IS NOT NULL);

-- No INSERT/UPDATE/DELETE for regular users (admin managed)

-- =====================================================
-- USER_ACHIEVEMENTS TABLE POLICIES
-- =====================================================

-- SELECT: Users see their own progress
CREATE POLICY "user_achievements_select_policy" ON public.user_achievements
    FOR SELECT USING (user_id = auth.uid());

-- INSERT/UPDATE: System-managed through functions
-- No direct insert/update policies

-- =====================================================
-- DAILY_STREAKS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see their own streaks
CREATE POLICY "daily_streaks_select_policy" ON public.daily_streaks
    FOR SELECT USING (user_id = auth.uid());

-- INSERT/UPDATE: System-managed through functions
-- No direct insert/update policies

-- =====================================================
-- USER_SUBSCRIPTIONS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see their own records
CREATE POLICY "user_subscriptions_select_policy" ON public.user_subscriptions
    FOR SELECT USING (user_id = auth.uid());

-- INSERT: System-managed through payment functions
-- No direct insert policy

-- =====================================================
-- PROFILE_BOOSTS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see their own boosts
CREATE POLICY "profile_boosts_select_policy" ON public.profile_boosts
    FOR SELECT USING (user_id = auth.uid());

-- INSERT: System-managed
-- No direct insert policy

-- =====================================================
-- VIRTUAL_GIFTS TABLE POLICIES
-- =====================================================

-- SELECT: Users can see gifts they sent or received
CREATE POLICY "virtual_gifts_select_policy" ON public.virtual_gifts
    FOR SELECT USING (sender_id = auth.uid() OR receiver_id = auth.uid());

-- INSERT: System-managed through payment functions
-- No direct insert policy

-- =====================================================
-- ADMIN_SETTINGS TABLE POLICIES
-- =====================================================

-- SELECT: Public read (for app config)
CREATE POLICY "admin_settings_select_policy" ON public.admin_settings
    FOR SELECT USING (true);

-- UPDATE: Admin only
CREATE POLICY "admin_settings_update_policy" ON public.admin_settings
    FOR UPDATE USING (public.is_admin(auth.uid()));

-- =====================================================
-- ADMIN_AUDIT_LOG TABLE POLICIES
-- =====================================================

-- SELECT: Admin only
CREATE POLICY "admin_audit_log_select_policy" ON public.admin_audit_log
    FOR SELECT USING (public.is_admin(auth.uid()));

-- INSERT: Admin only
CREATE POLICY "admin_audit_log_insert_policy" ON public.admin_audit_log
    FOR INSERT WITH CHECK (public.is_admin(auth.uid()));

-- =====================================================
-- POLLS TABLE POLICIES
-- =====================================================

-- SELECT: Authenticated users can see polls
CREATE POLICY "polls_select_policy" ON public.polls
    FOR SELECT USING (auth.uid() IS NOT NULL AND is_active = true);

-- INSERT: Users can create polls
CREATE POLICY "polls_insert_policy" ON public.polls
    FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- UPDATE: Poll creator can update
CREATE POLICY "polls_update_policy" ON public.polls
    FOR UPDATE USING (created_by = auth.uid());

-- =====================================================
-- POLL_VOTES TABLE POLICIES
-- =====================================================

-- SELECT: Users see their own votes
CREATE POLICY "poll_votes_select_policy" ON public.poll_votes
    FOR SELECT USING (user_id = auth.uid());

-- INSERT: Users can vote
CREATE POLICY "poll_votes_insert_policy" ON public.poll_votes
    FOR INSERT WITH CHECK (user_id = auth.uid());

-- =====================================================
-- END OF RLS POLICIES SCRIPT
-- =====================================================
-- =====================================================
-- COLONY APP - FUNCTIONS AND TRIGGERS
-- =====================================================
-- This script creates all SQL functions and triggers
-- for the Colony app backend.
-- =====================================================

-- =====================================================
-- FUNCTION 1: handle_new_user()
-- =====================================================
-- Trigger: AFTER INSERT on auth.users
-- Creates a profile row automatically when user signs up
-- =====================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
    base_username TEXT;
    final_username TEXT;
    suffix INTEGER;
BEGIN
    -- Extract base username from email (part before @)
    base_username := split_part(NEW.email, '@', 1);
    
    -- Clean username: remove special characters, convert to lowercase
    base_username := lower(regexp_replace(base_username, '[^a-zA-Z0-9_]', '', 'g'));
    
    -- Check if username exists, add random 4 digits if taken
    final_username := base_username;
    suffix := 0;
    
    WHILE EXISTS (SELECT 1 FROM public.profiles WHERE username = final_username) LOOP
        suffix := floor(random() * 9000 + 1000)::INTEGER;
        final_username := base_username || suffix::TEXT;
    END LOOP;
    
    -- Insert profile with id matching auth.users
    INSERT INTO public.profiles (id, email, username, full_name)
    VALUES (
        NEW.id,
        NEW.email,
        final_username,
        COALESCE(NEW.raw_user_meta_data->>'full_name', final_username)
    );
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.handle_new_user() IS 'Auto-creates profile when user signs up via Supabase Auth';

-- Create trigger for new user signup
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW
    EXECUTE FUNCTION public.handle_new_user();

-- =====================================================
-- FUNCTION 2: get_nearby_users()
-- =====================================================
-- Uses Haversine formula to find users within radius
-- Excludes: current user, blocked users, banned, ghost mode
-- =====================================================

CREATE OR REPLACE FUNCTION public.get_nearby_users(
    user_lat DOUBLE PRECISION,
    user_lng DOUBLE PRECISION,
    radius_km DOUBLE PRECISION,
    current_user_id UUID
)
RETURNS TABLE (
    id UUID,
    username TEXT,
    full_name TEXT,
    avatar_url TEXT,
    bio TEXT,
    profession TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    distance_meters DOUBLE PRECISION,
    is_online BOOLEAN,
    last_seen TIMESTAMPTZ,
    looking_for TEXT[],
    interests TEXT[],
    colony_level INTEGER,
    is_verified BOOLEAN,
    is_premium BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        p.id,
        p.username,
        p.full_name,
        p.avatar_url,
        p.bio,
        p.profession,
        p.latitude,
        p.longitude,
        -- Haversine formula for distance calculation
        (6371000 * acos(
            cos(radians(user_lat)) * cos(radians(p.latitude)) *
            cos(radians(p.longitude) - radians(user_lng)) +
            sin(radians(user_lat)) * sin(radians(p.latitude))
        )) AS distance_meters,
        p.is_online,
        p.last_seen,
        p.looking_for,
        p.interests,
        p.colony_level,
        p.is_verified,
        p.is_premium
    FROM public.profiles p
    WHERE 
        p.id != current_user_id
        AND p.is_banned = false
        AND p.ghost_mode = false
        AND p.latitude IS NOT NULL
        AND p.longitude IS NOT NULL
        -- Exclude blocked users (both directions)
        AND NOT public.are_users_blocked(current_user_id, p.id)
        -- Filter by radius using Haversine
        AND (6371000 * acos(
            cos(radians(user_lat)) * cos(radians(p.latitude)) *
            cos(radians(p.longitude) - radians(user_lng)) +
            sin(radians(user_lat)) * sin(radians(p.latitude))
        )) <= (radius_km * 1000)
    ORDER BY 
        p.is_online DESC,
        distance_meters ASC
    LIMIT 50;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_nearby_users(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, UUID) IS 'Find nearby users within radius using Haversine formula';

-- =====================================================
-- FUNCTION 3: get_nearby_events()
-- =====================================================
-- Finds active events within radius that haven't ended
-- Returns event details with creator info and distance
-- =====================================================

CREATE OR REPLACE FUNCTION public.get_nearby_events(
    user_lat DOUBLE PRECISION,
    user_lng DOUBLE PRECISION,
    radius_km DOUBLE PRECISION
)
RETURNS TABLE (
    id UUID,
    title TEXT,
    description TEXT,
    cover_image_url TEXT,
    event_type TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    location_name TEXT,
    address TEXT,
    starts_at TIMESTAMPTZ,
    ends_at TIMESTAMPTZ,
    max_attendees INTEGER,
    current_attendees INTEGER,
    is_free BOOLEAN,
    price DECIMAL,
    created_by UUID,
    group_id UUID,
    distance_meters DOUBLE PRECISION,
    creator_name TEXT,
    creator_avatar TEXT,
    response_count BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        e.id,
        e.title,
        e.description,
        e.cover_image_url,
        e.event_type,
        e.latitude,
        e.longitude,
        e.location_name,
        e.address,
        e.starts_at,
        e.ends_at,
        e.max_attendees,
        e.current_attendees,
        e.is_free,
        e.price,
        e.created_by,
        e.group_id,
        (6371000 * acos(
            cos(radians(user_lat)) * cos(radians(e.latitude)) *
            cos(radians(e.longitude) - radians(user_lng)) +
            sin(radians(user_lat)) * sin(radians(e.latitude))
        )) AS distance_meters,
        p.full_name AS creator_name,
        p.avatar_url AS creator_avatar,
        (SELECT COUNT(*) FROM public.event_responses er WHERE er.event_id = e.id AND er.status = 'going') AS response_count
    FROM public.events e
    LEFT JOIN public.profiles p ON p.id = e.created_by
    WHERE 
        e.is_active = true
        AND (e.ends_at IS NULL OR e.ends_at > now())
        AND (6371000 * acos(
            cos(radians(user_lat)) * cos(radians(e.latitude)) *
            cos(radians(e.longitude) - radians(user_lng)) +
            sin(radians(user_lat)) * sin(radians(e.latitude))
        )) <= (radius_km * 1000)
    ORDER BY e.starts_at ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_nearby_events(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION) IS 'Find nearby active events within radius';

-- =====================================================
-- FUNCTION 4: get_nearby_groups()
-- =====================================================
-- Finds active groups within radius
-- Returns group details with membership status
-- =====================================================

CREATE OR REPLACE FUNCTION public.get_nearby_groups(
    user_lat DOUBLE PRECISION,
    user_lng DOUBLE PRECISION,
    radius_km DOUBLE PRECISION,
    current_user_id UUID
)
RETURNS TABLE (
    id UUID,
    name TEXT,
    description TEXT,
    cover_image_url TEXT,
    icon_url TEXT,
    category TEXT,
    latitude DOUBLE PRECISION,
    longitude DOUBLE PRECISION,
    location_name TEXT,
    radius_km DOUBLE PRECISION,
    max_members INTEGER,
    member_count INTEGER,
    is_private BOOLEAN,
    join_approval_required BOOLEAN,
    created_by UUID,
    is_premium_group BOOLEAN,
    distance_meters DOUBLE PRECISION,
    is_member BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        g.id,
        g.name,
        g.description,
        g.cover_image_url,
        g.icon_url,
        g.category,
        g.latitude,
        g.longitude,
        g.location_name,
        g.radius_km,
        g.max_members,
        g.member_count,
        g.is_private,
        g.join_approval_required,
        g.created_by,
        g.is_premium_group,
        (6371000 * acos(
            cos(radians(user_lat)) * cos(radians(g.latitude)) *
            cos(radians(g.longitude) - radians(user_lng)) +
            sin(radians(user_lat)) * sin(radians(g.latitude))
        )) AS distance_meters,
        EXISTS (
            SELECT 1 FROM public.group_members gm
            WHERE gm.group_id = g.id AND gm.user_id = current_user_id
        ) AS is_member
    FROM public.groups g
    WHERE 
        g.is_active = true
        AND (6371000 * acos(
            cos(radians(user_lat)) * cos(radians(g.latitude)) *
            cos(radians(g.longitude) - radians(user_lng)) +
            sin(radians(user_lat)) * sin(radians(g.latitude))
        )) <= (radius_km * 1000)
    ORDER BY 
        g.member_count DESC,
        distance_meters ASC;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_nearby_groups(DOUBLE PRECISION, DOUBLE PRECISION, DOUBLE PRECISION, UUID) IS 'Find nearby groups within radius with membership status';

-- =====================================================
-- FUNCTION 5: accept_wave()
-- =====================================================
-- Accepts a wave and creates connection + conversation
-- Validates wave belongs to current user
-- =====================================================

CREATE OR REPLACE FUNCTION public.accept_wave(
    wave_id UUID,
    current_user_id UUID
)
RETURNS UUID AS $$
DECLARE
    v_wave public.waves%ROWTYPE;
    v_conversation_id UUID;
    v_user1 UUID;
    v_user2 UUID;
BEGIN
    -- Get the wave and validate
    SELECT * INTO v_wave FROM public.waves WHERE id = wave_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Wave not found';
    END IF;
    
    IF v_wave.receiver_id != current_user_id THEN
        RAISE EXCEPTION 'Not authorized to accept this wave';
    END IF;
    
    IF v_wave.status != 'pending' THEN
        RAISE EXCEPTION 'Wave is not pending';
    END IF;
    
    -- Update wave status
    UPDATE public.waves 
    SET status = 'accepted' 
    WHERE id = wave_id;
    
    -- Create connection (ensure user1_id < user2_id)
    IF v_wave.sender_id < current_user_id THEN
        v_user1 := v_wave.sender_id;
        v_user2 := current_user_id;
    ELSE
        v_user1 := current_user_id;
        v_user2 := v_wave.sender_id;
    END IF;
    
    INSERT INTO public.connections (user1_id, user2_id, connection_source)
    VALUES (v_user1, v_user2, 'wave')
    ON CONFLICT (user1_id, user2_id) DO NOTHING;
    
    -- Create direct conversation
    INSERT INTO public.conversations (type)
    VALUES ('direct')
    RETURNING id INTO v_conversation_id;
    
    -- Add both users as participants
    INSERT INTO public.conversation_participants (conversation_id, user_id, role)
    VALUES 
        (v_conversation_id, v_wave.sender_id, 'member'),
        (v_conversation_id, current_user_id, 'member');
    
    -- Create notification for wave sender
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (
        v_wave.sender_id,
        'wave_accepted',
        'Wave Accepted!',
        'Your wave was accepted! You can now chat.',
        jsonb_build_object('wave_id', wave_id, 'conversation_id', v_conversation_id, 'user_id', current_user_id)
    );
    
    -- Award karma to both users
    PERFORM public.increment_karma(v_wave.sender_id, 5);
    PERFORM public.increment_karma(current_user_id, 5);
    
    RETURN v_conversation_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.accept_wave(UUID, UUID) IS 'Accept a wave and create connection + conversation';

-- =====================================================
-- FUNCTION 6: update_user_location()
-- =====================================================
-- Updates user's location and online status
-- =====================================================

CREATE OR REPLACE FUNCTION public.update_user_location(
    p_user_id UUID,
    p_lat DOUBLE PRECISION,
    p_lng DOUBLE PRECISION,
    p_loc_name TEXT DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    UPDATE public.profiles
    SET 
        latitude = p_lat,
        longitude = p_lng,
        location_name = COALESCE(p_loc_name, location_name),
        last_location_update = now(),
        is_online = true,
        last_seen = now()
    WHERE id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.update_user_location(UUID, DOUBLE PRECISION, DOUBLE PRECISION, TEXT) IS 'Update user location and online status';

-- =====================================================
-- FUNCTION 7: check_device_limit()
-- =====================================================
-- Counts distinct users linked to a device
-- =====================================================

CREATE OR REPLACE FUNCTION public.check_device_limit(
    p_device_id TEXT
)
RETURNS INTEGER AS $$
DECLARE
    user_count INTEGER;
BEGIN
    SELECT COUNT(DISTINCT user_id) INTO user_count
    FROM public.device_logs
    WHERE device_id = p_device_id AND is_active = true;
    
    RETURN user_count;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.check_device_limit(TEXT) IS 'Count distinct users linked to a device';

-- =====================================================
-- FUNCTION 8: increment_karma()
-- =====================================================
-- Adds karma and checks achievement thresholds
-- =====================================================

CREATE OR REPLACE FUNCTION public.increment_karma(
    p_user_id UUID,
    p_amount INTEGER
)
RETURNS INTEGER AS $$
DECLARE
    new_karma INTEGER;
BEGIN
    -- Update karma
    UPDATE public.profiles
    SET karma_points = karma_points + p_amount
    WHERE id = p_user_id
    RETURNING karma_points INTO new_karma;
    
    -- Check for karma-related achievements (if we add them)
    -- This can be extended later
    
    RETURN new_karma;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.increment_karma(UUID, INTEGER) IS 'Add karma points to user and return new total';

-- =====================================================
-- FUNCTION 9: check_and_update_streak()
-- =====================================================
-- Updates user activity streak
-- Awards karma for milestone streaks
-- =====================================================

CREATE OR REPLACE FUNCTION public.check_and_update_streak(
    p_user_id UUID,
    p_streak_type TEXT
)
RETURNS INTEGER AS $$
DECLARE
    v_streak public.daily_streaks%ROWTYPE;
    v_today DATE := CURRENT_DATE;
    v_yesterday DATE := CURRENT_DATE - 1;
    new_streak INTEGER;
    karma_bonus INTEGER := 0;
BEGIN
    -- Get or create streak record
    SELECT * INTO v_streak 
    FROM public.daily_streaks 
    WHERE user_id = p_user_id AND streak_type = p_streak_type;
    
    IF NOT FOUND THEN
        -- Create new streak
        INSERT INTO public.daily_streaks (user_id, streak_type, current_streak, longest_streak, last_activity_date)
        VALUES (p_user_id, p_streak_type, 1, 1, v_today)
        RETURNING current_streak INTO new_streak;
        
        RETURN new_streak;
    END IF;
    
    -- Check last activity date
    IF v_streak.last_activity_date = v_today THEN
        -- Already recorded today, no change
        RETURN v_streak.current_streak;
        
    ELSIF v_streak.last_activity_date = v_yesterday THEN
        -- Consecutive day, increment streak
        new_streak := v_streak.current_streak + 1;
        
        UPDATE public.daily_streaks
        SET 
            current_streak = new_streak,
            longest_streak = GREATEST(longest_streak, new_streak),
            last_activity_date = v_today
        WHERE id = v_streak.id;
        
        -- Award karma for milestones
        CASE new_streak
            WHEN 7 THEN karma_bonus := 50;
            WHEN 14 THEN karma_bonus := 75;
            WHEN 30 THEN karma_bonus := 200;
            WHEN 60 THEN karma_bonus := 300;
            WHEN 100 THEN karma_bonus := 500;
            ELSE karma_bonus := 0;
        END CASE;
        
        IF karma_bonus > 0 THEN
            PERFORM public.increment_karma(p_user_id, karma_bonus);
        END IF;
        
    ELSE
        -- Streak broken, reset to 1
        new_streak := 1;
        
        UPDATE public.daily_streaks
        SET 
            current_streak = 1,
            last_activity_date = v_today
        WHERE id = v_streak.id;
    END IF;
    
    RETURN new_streak;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.check_and_update_streak(UUID, TEXT) IS 'Update activity streak and award milestone karma';

-- =====================================================
-- FUNCTION 10: get_user_stats()
-- =====================================================
-- Returns user statistics for profile
-- =====================================================

CREATE OR REPLACE FUNCTION public.get_user_stats(
    p_user_id UUID
)
RETURNS TABLE (
    connections_count BIGINT,
    groups_count BIGINT,
    events_hosted_count BIGINT,
    stories_count BIGINT,
    karma_points INTEGER,
    colony_level INTEGER,
    current_streak INTEGER
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        -- Connections count
        (SELECT COUNT(*) FROM public.connections 
         WHERE user1_id = p_user_id OR user2_id = p_user_id) AS connections_count,
        
        -- Groups count
        (SELECT COUNT(*) FROM public.group_members 
         WHERE user_id = p_user_id AND status = 'active') AS groups_count,
        
        -- Events hosted count
        (SELECT COUNT(*) FROM public.events 
         WHERE created_by = p_user_id) AS events_hosted_count,
        
        -- Stories count
        (SELECT COUNT(*) FROM public.stories 
         WHERE user_id = p_user_id) AS stories_count,
        
        -- Karma points
        p.karma_points,
        
        -- Colony level
        p.colony_level,
        
        -- Current streak (app_open type)
        COALESCE(
            (SELECT current_streak FROM public.daily_streaks 
             WHERE user_id = p_user_id AND streak_type = 'app_open'),
            0
        ) AS current_streak
    FROM public.profiles p
    WHERE p.id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.get_user_stats(UUID) IS 'Get user statistics including connections, groups, events, karma, and streaks';

-- =====================================================
-- ADDITIONAL HELPER FUNCTIONS
-- =====================================================

-- Function to create a notification
CREATE OR REPLACE FUNCTION public.create_notification(
    p_user_id UUID,
    p_type TEXT,
    p_title TEXT,
    p_body TEXT DEFAULT NULL,
    p_data JSONB DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
    v_notification_id UUID;
BEGIN
    INSERT INTO public.notifications (user_id, type, title, body, data)
    VALUES (p_user_id, p_type, p_title, p_body, p_data)
    RETURNING id INTO v_notification_id;
    
    RETURN v_notification_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.create_notification(UUID, TEXT, TEXT, TEXT, JSONB) IS 'Create a notification for a user';

-- Function to soft delete a message
CREATE OR REPLACE FUNCTION public.soft_delete_message(
    p_message_id UUID,
    p_user_id UUID
)
RETURNS BOOLEAN AS $$
DECLARE
    v_message public.messages%ROWTYPE;
BEGIN
    SELECT * INTO v_message FROM public.messages WHERE id = p_message_id;
    
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    
    IF v_message.sender_id != p_user_id THEN
        RAISE EXCEPTION 'Not authorized to delete this message';
    END IF;
    
    UPDATE public.messages
    SET is_deleted = true
    WHERE id = p_message_id;
    
    RETURN true;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.soft_delete_message(UUID, UUID) IS 'Soft delete a message (mark as deleted)';

-- Function to update member count in groups
CREATE OR REPLACE FUNCTION public.update_group_member_count()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        UPDATE public.groups
        SET member_count = member_count + 1
        WHERE id = NEW.group_id;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        UPDATE public.groups
        SET member_count = member_count - 1
        WHERE id = OLD.group_id;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.update_group_member_count() IS 'Trigger to update group member count';

-- Apply trigger for group member count
DROP TRIGGER IF EXISTS update_group_member_count_trigger ON public.group_members;
CREATE TRIGGER update_group_member_count_trigger
    AFTER INSERT OR DELETE ON public.group_members
    FOR EACH ROW
    EXECUTE FUNCTION public.update_group_member_count();

-- Function to update attendee count in events
CREATE OR REPLACE FUNCTION public.update_event_attendee_count()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.status = 'going' THEN
            UPDATE public.events
            SET current_attendees = current_attendees + 1
            WHERE id = NEW.event_id;
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        IF OLD.status = 'going' AND NEW.status != 'going' THEN
            UPDATE public.events
            SET current_attendees = current_attendees - 1
            WHERE id = NEW.event_id;
        ELSIF OLD.status != 'going' AND NEW.status = 'going' THEN
            UPDATE public.events
            SET current_attendees = current_attendees + 1
            WHERE id = NEW.event_id;
        END IF;
        RETURN NEW;
    ELSIF TG_OP = 'DELETE' THEN
        IF OLD.status = 'going' THEN
            UPDATE public.events
            SET current_attendees = current_attendees - 1
            WHERE id = OLD.event_id;
        END IF;
        RETURN OLD;
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.update_event_attendee_count() IS 'Trigger to update event attendee count';

-- Apply trigger for event attendee count
DROP TRIGGER IF EXISTS update_event_attendee_count_trigger ON public.event_responses;
CREATE TRIGGER update_event_attendee_count_trigger
    AFTER INSERT OR UPDATE OR DELETE ON public.event_responses
    FOR EACH ROW
    EXECUTE FUNCTION public.update_event_attendee_count();

-- Function to update story view count
CREATE OR REPLACE FUNCTION public.update_story_view_count()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE public.stories
    SET view_count = view_count + 1
    WHERE id = NEW.story_id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION public.update_story_view_count() IS 'Trigger to update story view count';

-- Apply trigger for story view count
DROP TRIGGER IF EXISTS update_story_view_count_trigger ON public.story_views;
CREATE TRIGGER update_story_view_count_trigger
    AFTER INSERT ON public.story_views
    FOR EACH ROW
    EXECUTE FUNCTION public.update_story_view_count();

-- =====================================================
-- END OF FUNCTIONS AND TRIGGERS SCRIPT
-- =====================================================
-- =====================================================
-- COLONY APP - REALTIME CONFIGURATION
-- =====================================================
-- This script enables Supabase Realtime on tables
-- that need real-time updates for the app.
-- =====================================================

-- =====================================================
-- ENABLE REALTIME ON TABLES
-- =====================================================
-- Realtime allows clients to subscribe to changes
-- via WebSocket connections for instant updates.
-- =====================================================

-- Enable realtime publication (if not already exists)
-- Supabase creates 'supabase_realtime' publication by default

-- Add tables to the realtime publication
-- These tables will broadcast INSERT, UPDATE, DELETE events

-- Messages: Real-time chat messages
ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;

-- Conversations: Conversation updates (new chats, etc.)
ALTER PUBLICATION supabase_realtime ADD TABLE public.conversations;

-- Conversation Participants: Join/leave events
ALTER PUBLICATION supabase_realtime ADD TABLE public.conversation_participants;

-- Waves: Real-time wave notifications
ALTER PUBLICATION supabase_realtime ADD TABLE public.waves;

-- Notifications: Real-time notification badges
ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;

-- Profiles: Online status updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.profiles;

-- Stories: New stories from followed users
ALTER PUBLICATION supabase_realtime ADD TABLE public.stories;

-- Message Reactions: Real-time emoji reactions
ALTER PUBLICATION supabase_realtime ADD TABLE public.message_reactions;

-- Story Views: View count updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.story_views;

-- Connections: New connection notifications
ALTER PUBLICATION supabase_realtime ADD TABLE public.connections;

-- Groups: Group updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.groups;

-- Group Members: Membership changes
ALTER PUBLICATION supabase_realtime ADD TABLE public.group_members;

-- Events: Event updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.events;

-- Event Responses: RSVP updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.event_responses;

-- Polls: Poll updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.polls;

-- Poll Votes: Vote updates
ALTER PUBLICATION supabase_realtime ADD TABLE public.poll_votes;

-- =====================================================
-- REALTIME REPLICA IDENTITY
-- =====================================================
-- Set replica identity to FULL for tables where we need
-- the old row data in change events (for diffing).
-- This is important for UPDATE events.
-- =====================================================

ALTER TABLE public.messages REPLICA IDENTITY FULL;
ALTER TABLE public.conversations REPLICA IDENTITY FULL;
ALTER TABLE public.conversation_participants REPLICA IDENTITY FULL;
ALTER TABLE public.waves REPLICA IDENTITY FULL;
ALTER TABLE public.notifications REPLICA IDENTITY FULL;
ALTER TABLE public.profiles REPLICA IDENTITY FULL;
ALTER TABLE public.stories REPLICA IDENTITY FULL;
ALTER TABLE public.message_reactions REPLICA IDENTITY FULL;
ALTER TABLE public.connections REPLICA IDENTITY FULL;
ALTER TABLE public.groups REPLICA IDENTITY FULL;
ALTER TABLE public.group_members REPLICA IDENTITY FULL;
ALTER TABLE public.events REPLICA IDENTITY FULL;
ALTER TABLE public.event_responses REPLICA IDENTITY FULL;
ALTER TABLE public.polls REPLICA IDENTITY FULL;
ALTER TABLE public.poll_votes REPLICA IDENTITY FULL;

-- =====================================================
-- VERIFICATION QUERY
-- =====================================================
-- Run this to verify realtime is configured correctly:
-- 
-- SELECT schemaname, tablename 
-- FROM pg_publication_tables 
-- WHERE pubname = 'supabase_realtime'
-- ORDER BY tablename;
-- =====================================================

-- =====================================================
-- END OF REALTIME CONFIGURATION SCRIPT
-- =====================================================
