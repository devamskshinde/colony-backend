-- =====================================================
-- MIGRATION: Add onboarding_completed column
-- =====================================================
-- This migration adds the onboarding_completed column to
-- the profiles table to track if user has completed the
-- onboarding flow.
-- =====================================================

-- Add onboarding_completed column to profiles table
ALTER TABLE public.profiles 
ADD COLUMN IF NOT EXISTS onboarding_completed BOOLEAN DEFAULT false;

-- Add comment to the column
COMMENT ON COLUMN public.profiles.onboarding_completed IS 'Tracks if user has completed the onboarding flow (profile setup, interests, location)';

-- Update the handle_new_user() function to set onboarding_completed = false by default
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
  -- onboarding_completed defaults to false
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

COMMENT ON FUNCTION public.handle_new_user() IS 'Auto-creates profile when user signs up via Supabase Auth. Sets onboarding_completed = false by default.';

-- Create index for faster queries on onboarding_completed
CREATE INDEX IF NOT EXISTS idx_profiles_onboarding_completed 
ON public.profiles(onboarding_completed) 
WHERE onboarding_completed = false;

-- Update existing profiles that don't have the column set
UPDATE public.profiles 
SET onboarding_completed = false 
WHERE onboarding_completed IS NULL;
