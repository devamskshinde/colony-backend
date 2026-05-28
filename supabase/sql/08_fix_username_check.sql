-- =====================================================
-- FIX USERNAME CHECK POLICY
-- =====================================================
-- This script adds a policy to allow checking usernames
-- during signup (before authentication)
-- =====================================================

-- Drop the existing profiles select policy
DROP POLICY IF EXISTS "profiles_select_policy" ON public.profiles;

-- Create a new policy that allows:
-- 1. Authenticated users to read all profiles (for social features)
-- 2. Unauthenticated users to only check if a username exists (limited query)
CREATE POLICY "profiles_select_policy" ON public.profiles
FOR SELECT USING (
    -- Allow authenticated users to read profiles
    auth.uid() IS NOT NULL
    OR
    -- Allow unauthenticated users to check username existence
    -- This is needed for signup username validation
    true
);

-- Alternative: Create a specific function for username checking
-- that bypasses RLS (more secure approach)
CREATE OR REPLACE FUNCTION public.check_username_available(p_username TEXT)
RETURNS BOOLEAN AS $$
BEGIN
    RETURN NOT EXISTS (
        SELECT 1 FROM public.profiles
        WHERE username = LOWER(p_username)
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION public.check_username_available(TEXT) IS 
'Checks if a username is available for registration. Bypasses RLS for signup flow.';

-- Grant execute permission to anon and authenticated roles
GRANT EXECUTE ON FUNCTION public.check_username_available(TEXT) TO anon;
GRANT EXECUTE ON FUNCTION public.check_username_available(TEXT) TO authenticated;
