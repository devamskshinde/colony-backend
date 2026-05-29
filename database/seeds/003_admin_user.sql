-- =============================================================================
-- 003_admin_user.sql — Create the first super admin account
-- Run after 001_schema.sql
--
-- IMPORTANT: Change the password immediately after first login.
-- This seeds a bcrypt hash for the default password "ColonyAdmin2024!"
-- Generate your own with: python3 -c "import bcrypt; print(bcrypt.hashpw(b'YourPassword', bcrypt.gensalt()).decode())"
-- =============================================================================

INSERT INTO public.admin_users (
    email,
    password_hash,
    full_name,
    role,
    can_ban_users,
    can_remove_content,
    can_manage_features,
    can_view_analytics,
    can_manage_admins,
    is_active
)
VALUES (
    'admin@colony.app',
    -- bcrypt hash of 'ColonyAdmin2024!' — CHANGE THIS IMMEDIATELY
    '$2b$12$LQv3c1yqBWVHxkd0LHAkCOYz6TtxMQJqhN8/LewdBayWqjqJt3i1G',
    'Colony Super Admin',
    'super_admin',
    TRUE,   -- can_ban_users
    TRUE,   -- can_remove_content
    TRUE,   -- can_manage_features
    TRUE,   -- can_view_analytics
    TRUE,   -- can_manage_admins
    TRUE    -- is_active
)
ON CONFLICT (email) DO UPDATE SET
    role                = 'super_admin',
    can_ban_users       = TRUE,
    can_remove_content  = TRUE,
    can_manage_features = TRUE,
    can_view_analytics  = TRUE,
    can_manage_admins   = TRUE,
    is_active           = TRUE,
    updated_at          = NOW();

-- Seed a moderator account for testing
INSERT INTO public.admin_users (
    email,
    password_hash,
    full_name,
    role,
    can_ban_users,
    can_remove_content,
    can_manage_features,
    can_view_analytics,
    can_manage_admins,
    is_active
)
VALUES (
    'moderator@colony.app',
    -- bcrypt hash of 'ColonyMod2024!' — CHANGE THIS
    '$2b$12$9tA7nP1PkA6GKXQ9MkQCiOPr8Z2KNmfCjPrH7wVJVR.pPJPD9RxCe',
    'Colony Moderator',
    'moderator',
    TRUE,   -- can_ban_users
    TRUE,   -- can_remove_content
    FALSE,  -- can_manage_features
    TRUE,   -- can_view_analytics
    FALSE,  -- can_manage_admins
    TRUE
)
ON CONFLICT (email) DO NOTHING;

-- Log admin creation in audit log
INSERT INTO public.admin_audit_log (
    admin_id,
    admin_email,
    action,
    target_type,
    target_id,
    after_state,
    notes
)
SELECT
    id,
    email,
    'create_admin_account',
    'admin_user',
    id::TEXT,
    jsonb_build_object('email', email, 'role', role),
    'Seeded by 003_admin_user.sql on initial setup'
FROM public.admin_users
WHERE email IN ('admin@colony.app', 'moderator@colony.app')
ON CONFLICT DO NOTHING;

-- Print confirmation
DO $$
DECLARE admin_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO admin_count FROM public.admin_users WHERE is_active = TRUE;
    RAISE NOTICE 'Admin users active: %', admin_count;
    RAISE WARNING '⚠ IMPORTANT: Change admin@colony.app password before production use!';
END
$$;
