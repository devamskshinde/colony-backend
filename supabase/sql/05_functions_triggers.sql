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
    p_radius_km DOUBLE PRECISION,
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
        )) <= (p_radius_km * 1000)
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
