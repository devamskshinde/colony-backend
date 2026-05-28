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
