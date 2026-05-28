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
