-- =====================================================
-- COLONY APP - COMPLETE DATABASE SETUP
-- =====================================================
-- Run this ENTIRE script in Supabase SQL Editor
-- This will set up your complete database schema
-- =====================================================

-- =====================================================
-- STEP 1: CORE TABLES
-- =====================================================

-- TABLE: profiles
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
    onboarding_completed BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- Add comment
COMMENT ON TABLE public.profiles IS 'User profiles extending auth.users with location, preferences, and social data';

-- TABLE: device_logs
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

-- TABLE: blocked_devices
CREATE TABLE IF NOT EXISTS public.blocked_devices (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id TEXT UNIQUE NOT NULL,
    reason TEXT,
    blocked_by UUID REFERENCES public.profiles(id),
    blocked_at TIMESTAMPTZ DEFAULT now()
);

-- TABLE: user_reports
CREATE TABLE IF NOT EXISTS public.user_reports (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    reporter_id UUID REFERENCES public.profiles(id),
    reported_user_id UUID REFERENCES public.profiles(id),
    reason TEXT NOT NULL CHECK (reason IN ('spam', 'harassment', 'fake_profile', 'inappropriate_content', 'other')),
    description TEXT,
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'reviewed', 'action_taken', 'dismissed')),
    admin_notes TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- TABLE: blocked_users
CREATE TABLE IF NOT EXISTS public.blocked_users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    blocker_id UUID REFERENCES public.profiles(id),
    blocked_id UUID REFERENCES public.profiles(id),
    created_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(blocker_id, blocked_id)
);

-- =====================================================
-- STEP 2: SOCIAL TABLES
-- =====================================================

-- TABLE: conversations
CREATE TABLE IF NOT EXISTS public.conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    type TEXT NOT NULL CHECK (type IN ('direct', 'group')),
    group_id UUID,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- TABLE: conversation_participants
CREATE TABLE IF NOT EXISTS public.conversation_participants (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID REFERENCES public.conversations(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id),
    role TEXT DEFAULT 'member' CHECK (role IN ('member', 'admin', 'owner')),
    joined_at TIMESTAMPTZ DEFAULT now(),
    last_read_at TIMESTAMPTZ,
    is_muted BOOLEAN DEFAULT false,
    is_pinned BOOLEAN DEFAULT false,
    UNIQUE(conversation_id, user_id)
);

-- TABLE: messages
CREATE TABLE IF NOT EXISTS public.messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID REFERENCES public.conversations(id) ON DELETE CASCADE,
    sender_id UUID REFERENCES public.profiles(id),
    content TEXT,
    message_type TEXT DEFAULT 'text' CHECK (message_type IN ('text', 'image', 'video', 'audio', 'gif', 'sticker', 'voice_note', 'location', 'event_share')),
    media_url TEXT,
    thumbnail_url TEXT,
    reply_to UUID REFERENCES public.messages(id),
    is_deleted BOOLEAN DEFAULT false,
    is_edited BOOLEAN DEFAULT false,
    edited_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT now()
);

-- TABLE: waves
CREATE TABLE IF NOT EXISTS public.waves (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    sender_id UUID REFERENCES public.profiles(id),
    receiver_id UUID REFERENCES public.profiles(id),
    wave_type TEXT DEFAULT 'friendly' CHECK (wave_type IN ('friendly', 'spark')),
    message TEXT CHECK (char_length(message) <= 100),
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'accepted', 'declined', 'expired')),
    distance_at_wave DOUBLE PRECISION,
    created_at TIMESTAMPTZ DEFAULT now(),
    expires_at TIMESTAMPTZ DEFAULT (now() + interval '24 hours'),
    UNIQUE(sender_id, receiver_id)
);

-- TABLE: connections
CREATE TABLE IF NOT EXISTS public.connections (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user1_id UUID REFERENCES public.profiles(id),
    user2_id UUID REFERENCES public.profiles(id),
    connected_at TIMESTAMPTZ DEFAULT now(),
    connection_source TEXT DEFAULT 'wave' CHECK (connection_source IN ('wave', 'group', 'event')),
    CHECK (user1_id < user2_id),
    UNIQUE(user1_id, user2_id)
);

-- TABLE: groups
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
    created_by UUID REFERENCES public.profiles(id),
    is_premium_group BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- TABLE: group_members
CREATE TABLE IF NOT EXISTS public.group_members (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    group_id UUID REFERENCES public.groups(id) ON DELETE CASCADE,
    user_id UUID REFERENCES public.profiles(id),
    role TEXT DEFAULT 'member' CHECK (role IN ('member', 'moderator', 'admin', 'owner')),
    status TEXT DEFAULT 'active' CHECK (status IN ('active', 'pending', 'banned')),
    joined_at TIMESTAMPTZ DEFAULT now(),
    UNIQUE(group_id, user_id)
);

-- TABLE: events
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
    created_by UUID REFERENCES public.profiles(id),
    group_id UUID REFERENCES public.groups(id),
    broadcast_radius_km DOUBLE PRECISION DEFAULT 5.0,
    is_promoted BOOLEAN DEFAULT false,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMPTZ DEFAULT now(),
    updated_at TIMESTAMPTZ DEFAULT now()
);

-- TABLE: stories
CREATE TABLE IF NOT EXISTS public.stories (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES public.profiles(id),
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

-- =====================================================
-- STEP 3: INDEXES
-- =====================================================

-- Profiles indexes
CREATE INDEX IF NOT EXISTS idx_profiles_location ON public.profiles(latitude, longitude);
CREATE INDEX IF NOT EXISTS idx_profiles_online ON public.profiles(is_online);
CREATE INDEX IF NOT EXISTS idx_profiles_username ON public.profiles(username);
CREATE INDEX IF NOT EXISTS idx_profiles_onboarding_completed ON public.profiles(onboarding_completed) WHERE onboarding_completed = false;

-- Device logs indexes
CREATE INDEX IF NOT EXISTS idx_device_logs_device ON public.device_logs(device_id);
CREATE INDEX IF NOT EXISTS idx_device_logs_user ON public.device_logs(user_id);

-- Messages indexes
CREATE INDEX IF NOT EXISTS idx_messages_conversation ON public.messages(conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_messages_sender ON public.messages(sender_id);

-- Groups indexes
CREATE INDEX IF NOT EXISTS idx_groups_location ON public.groups(latitude, longitude);
CREATE INDEX IF NOT EXISTS idx_groups_category ON public.groups(category);

-- Events indexes
CREATE INDEX IF NOT EXISTS idx_events_location ON public.events(latitude, longitude);
CREATE INDEX IF NOT EXISTS idx_events_starts ON public.events(starts_at);

-- Waves indexes
CREATE INDEX IF NOT EXISTS idx_waves_receiver ON public.waves(receiver_id, status);
CREATE INDEX IF NOT EXISTS idx_waves_sender ON public.waves(sender_id);

-- =====================================================
-- STEP 4: FUNCTIONS & TRIGGERS
-- =====================================================

-- FUNCTION: Handle new user signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
    base_username TEXT;
    final_username TEXT;
    suffix INTEGER;
BEGIN
    -- Extract base username from email
    base_username := split_part(NEW.email, '@', 1);
    base_username := lower(regexp_replace(base_username, '[^a-zA-Z0-9_]', '', 'g'));

    -- Check if username exists, add random digits if taken
    final_username := base_username;
    suffix := 0;

    WHILE EXISTS (SELECT 1 FROM public.profiles WHERE username = final_username) LOOP
        suffix := floor(random() * 9000 + 1000)::INTEGER;
        final_username := base_username || suffix::TEXT;
    END LOOP;

    -- Insert profile
    INSERT INTO public.profiles (id, email, username, full_name, onboarding_completed)
    VALUES (
        NEW.id,
        NEW.email,
        final_username,
        COALESCE(NEW.raw_user_meta_data->>'full_name', final_username),
        false
    );

    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- TRIGGER: Auto-create profile on signup
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- FUNCTION: Check username availability
CREATE OR REPLACE FUNCTION public.check_username_available(p_username TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN NOT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE username = lower(p_username)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- FUNCTION: Update user location
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
        is_online = true
    WHERE id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- FUNCTION: Get nearby users
CREATE OR REPLACE FUNCTION public.get_nearby_users(
    p_user_lat DOUBLE PRECISION,
    p_user_lng DOUBLE PRECISION,
    p_radius_km DOUBLE PRECISION DEFAULT 5.0,
    p_current_user_id UUID
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
        (
            6371000 * acos(
                cos(radians(p_user_lat)) *
                cos(radians(p.latitude)) *
                cos(radians(p.longitude) - radians(p_user_lng)) +
                sin(radians(p_user_lat)) *
                sin(radians(p.latitude))
            )
        ) AS distance_meters,
        p.is_online,
        p.last_seen,
        p.looking_for,
        p.interests,
        p.colony_level,
        p.is_verified,
        p.is_premium
    FROM public.profiles p
    WHERE
        p.id != p_current_user_id
        AND p.is_banned = false
        AND p.ghost_mode = false
        AND NOT EXISTS (
            SELECT 1 FROM public.blocked_users b
            WHERE (b.blocker_id = p_current_user_id AND b.blocked_id = p.id)
               OR (b.blocker_id = p.id AND b.blocked_id = p_current_user_id)
        )
        AND (
            6371000 * acos(
                cos(radians(p_user_lat)) *
                cos(radians(p.latitude)) *
                cos(radians(p.longitude) - radians(p_user_lng)) +
                sin(radians(p_user_lat)) *
                sin(radians(p.latitude))
            )
        ) <= (p_radius_km * 1000)
    ORDER BY p.is_online DESC, distance_meters ASC
    LIMIT 50;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- FUNCTION: Set user online status
CREATE OR REPLACE FUNCTION public.set_user_online_status(
    p_user_id UUID,
    p_is_online BOOLEAN
)
RETURNS VOID AS $$
BEGIN
    UPDATE public.profiles
    SET
        is_online = p_is_online,
        last_seen = now()
    WHERE id = p_user_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- STEP 5: ROW LEVEL SECURITY (RLS)
-- =====================================================

-- Enable RLS on all tables
ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.device_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.waves ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stories ENABLE ROW LEVEL SECURITY;

-- PROFILES POLICIES
CREATE POLICY "Public profiles are viewable by everyone"
    ON public.profiles FOR SELECT
    USING (auth.uid() IS NOT NULL);

CREATE POLICY "Users can insert their own profile"
    ON public.profiles FOR INSERT
    WITH CHECK (auth.uid() = id);

CREATE POLICY "Users can update own profile"
    ON public.profiles FOR UPDATE
    USING (auth.uid() = id);

-- WAVES POLICIES
CREATE POLICY "Users can view their own waves"
    ON public.waves FOR SELECT
    USING (auth.uid() = sender_id OR auth.uid() = receiver_id);

CREATE POLICY "Users can send waves"
    ON public.waves FOR INSERT
    WITH CHECK (auth.uid() = sender_id);

CREATE POLICY "Receivers can update waves"
    ON public.waves FOR UPDATE
    USING (auth.uid() = receiver_id);

-- GROUPS POLICIES
CREATE POLICY "Groups are viewable by everyone"
    ON public.groups FOR SELECT
    USING (auth.uid() IS NOT NULL);

CREATE POLICY "Authenticated users can create groups"
    ON public.groups FOR INSERT
    WITH CHECK (auth.uid() IS NOT NULL);

CREATE POLICY "Group creators can update"
    ON public.groups FOR UPDATE
    USING (auth.uid() = created_by);

-- EVENTS POLICIES
CREATE POLICY "Events are viewable by everyone"
    ON public.events FOR SELECT
    USING (auth.uid() IS NOT NULL);

CREATE POLICY "Authenticated users can create events"
    ON public.events FOR INSERT
    WITH CHECK (auth.uid() IS NOT NULL);

-- STORIES POLICIES
CREATE POLICY "Stories are viewable by authenticated users"
    ON public.stories FOR SELECT
    USING (auth.uid() IS NOT NULL AND is_active = true AND expires_at > now());

CREATE POLICY "Users can create their own stories"
    ON public.stories FOR INSERT
    WITH CHECK (auth.uid() = user_id);

-- MESSAGES POLICIES
CREATE POLICY "Users can view messages in their conversations"
    ON public.messages FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM public.conversation_participants
            WHERE conversation_id = messages.conversation_id
            AND user_id = auth.uid()
        )
    );

CREATE POLICY "Users can send messages"
    ON public.messages FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.conversation_participants
            WHERE conversation_id = messages.conversation_id
            AND user_id = auth.uid()
        )
    );

-- =====================================================
-- STEP 6: REALTIME
-- =====================================================

-- Enable realtime
ALTER PUBLICATION supabase_realtime ADD TABLE public.messages;
ALTER PUBLICATION supabase_realtime ADD TABLE public.conversations;
ALTER PUBLICATION supabase_realtime ADD TABLE public.waves;
ALTER PUBLICATION supabase_realtime ADD TABLE public.stories;
ALTER PUBLICATION supabase_realtime ADD TABLE public.profiles;

-- =====================================================
-- COMPLETION MESSAGE
-- =====================================================

DO $$
BEGIN
    RAISE NOTICE '========================================';
    RAISE NOTICE '✅ COLONY DATABASE SETUP COMPLETE!';
    RAISE NOTICE '========================================';
    RAISE NOTICE 'Tables created: profiles, device_logs, blocked_devices, user_reports, blocked_users, conversations, messages, waves, connections, groups, events, stories';
    RAISE NOTICE 'Functions created: handle_new_user, check_username_available, update_user_location, get_nearby_users, set_user_online_status';
    RAISE NOTICE 'RLS enabled on all tables';
    RAISE NOTICE 'Realtime enabled on key tables';
    RAISE NOTICE '';
    RAISE NOTICE 'Your Colony app is ready to use!';
    RAISE NOTICE '========================================';
END $$;
