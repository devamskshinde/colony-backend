-- =====================================================
-- COLONY APP - STORAGE BUCKETS AND POLICIES
-- =====================================================
-- This script creates storage buckets for user uploads
-- and sets up appropriate access policies.
-- =====================================================

-- =====================================================
-- STORAGE BUCKETS
-- =====================================================

-- Bucket 1: avatars (public)
-- User profile pictures
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'avatars',
    'avatars',
    true,
    5242880, -- 5MB
    ARRAY['image/jpeg', 'image/png', 'image/webp']
) ON CONFLICT (id) DO NOTHING;

-- Bucket 2: stories (public)
-- Ephemeral story media (images and videos)
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'stories',
    'stories',
    true,
    20971520, -- 20MB (for videos)
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'video/mp4']
) ON CONFLICT (id) DO NOTHING;

-- Bucket 3: chat-media (private)
-- Media shared in chat conversations
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'chat-media',
    'chat-media',
    false, -- Private bucket
    26214400, -- 25MB
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'video/mp4', 'audio/mpeg', 'audio/m4a', 'audio/ogg']
) ON CONFLICT (id) DO NOTHING;

-- Bucket 4: group-covers (public)
-- Group cover images
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'group-covers',
    'group-covers',
    true,
    10485760, -- 10MB
    ARRAY['image/jpeg', 'image/png', 'image/webp']
) ON CONFLICT (id) DO NOTHING;

-- Bucket 5: event-covers (public)
-- Event cover images
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'event-covers',
    'event-covers',
    true,
    10485760, -- 10MB
    ARRAY['image/jpeg', 'image/png', 'image/webp']
) ON CONFLICT (id) DO NOTHING;

-- Bucket 6: visual-journal (public)
-- Visual journal/diary entries
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
    'visual-journal',
    'visual-journal',
    true,
    15728640, -- 15MB
    ARRAY['image/jpeg', 'image/png', 'image/webp', 'video/mp4']
) ON CONFLICT (id) DO NOTHING;

-- =====================================================
-- STORAGE POLICIES
-- =====================================================

-- =====================================================
-- AVATARS BUCKET POLICIES
-- =====================================================

-- SELECT: Anyone can read avatars (public bucket)
CREATE POLICY "avatars_select_policy" ON storage.objects
    FOR SELECT USING (bucket_id = 'avatars');

-- INSERT: Users can upload to their own folder (user_id/filename)
CREATE POLICY "avatars_insert_policy" ON storage.objects
    FOR INSERT WITH CHECK (
        bucket_id = 'avatars' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- UPDATE: Users can update their own uploads
CREATE POLICY "avatars_update_policy" ON storage.objects
    FOR UPDATE USING (
        bucket_id = 'avatars' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- DELETE: Users can delete their own uploads
CREATE POLICY "avatars_delete_policy" ON storage.objects
    FOR DELETE USING (
        bucket_id = 'avatars' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- =====================================================
-- STORIES BUCKET POLICIES
-- =====================================================

-- SELECT: Authenticated users can read stories
CREATE POLICY "stories_select_policy" ON storage.objects
    FOR SELECT USING (
        bucket_id = 'stories' 
        AND auth.uid() IS NOT NULL
    );

-- INSERT: Users can upload to their own folder
CREATE POLICY "stories_insert_policy" ON storage.objects
    FOR INSERT WITH CHECK (
        bucket_id = 'stories' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- UPDATE: Users can update their own uploads
CREATE POLICY "stories_update_policy" ON storage.objects
    FOR UPDATE USING (
        bucket_id = 'stories' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- DELETE: Users can delete their own uploads
CREATE POLICY "stories_delete_policy" ON storage.objects
    FOR DELETE USING (
        bucket_id = 'stories' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- =====================================================
-- CHAT-MEDIA BUCKET POLICIES
-- =====================================================

-- SELECT: Only conversation participants can read
-- Folder structure: conversation_id/filename
CREATE POLICY "chat_media_select_policy" ON storage.objects
    FOR SELECT USING (
        bucket_id = 'chat-media' 
        AND EXISTS (
            SELECT 1 FROM public.conversation_participants cp
            WHERE cp.conversation_id::text = (storage.foldername(name))[1]
            AND cp.user_id = auth.uid()
        )
    );

-- INSERT: Only conversation participants can upload
CREATE POLICY "chat_media_insert_policy" ON storage.objects
    FOR INSERT WITH CHECK (
        bucket_id = 'chat-media' 
        AND EXISTS (
            SELECT 1 FROM public.conversation_participants cp
            WHERE cp.conversation_id::text = (storage.foldername(name))[1]
            AND cp.user_id = auth.uid()
        )
    );

-- UPDATE: Only the uploader can update (owner check)
CREATE POLICY "chat_media_update_policy" ON storage.objects
    FOR UPDATE USING (
        bucket_id = 'chat-media' 
        AND auth.uid()::text = owner::text
    );

-- DELETE: Only the uploader can delete
CREATE POLICY "chat_media_delete_policy" ON storage.objects
    FOR DELETE USING (
        bucket_id = 'chat-media' 
        AND auth.uid()::text = owner::text
    );

-- =====================================================
-- GROUP-COVERS BUCKET POLICIES
-- =====================================================

-- SELECT: Anyone can read group covers (public)
CREATE POLICY "group_covers_select_policy" ON storage.objects
    FOR SELECT USING (bucket_id = 'group-covers');

-- INSERT: Group admins/owners can upload
-- Folder structure: group_id/filename
CREATE POLICY "group_covers_insert_policy" ON storage.objects
    FOR INSERT WITH CHECK (
        bucket_id = 'group-covers' 
        AND EXISTS (
            SELECT 1 FROM public.group_members gm
            WHERE gm.group_id::text = (storage.foldername(name))[1]
            AND gm.user_id = auth.uid()
            AND gm.role IN ('admin', 'owner')
        )
    );

-- UPDATE: Group admins/owners can update
CREATE POLICY "group_covers_update_policy" ON storage.objects
    FOR UPDATE USING (
        bucket_id = 'group-covers' 
        AND EXISTS (
            SELECT 1 FROM public.group_members gm
            WHERE gm.group_id::text = (storage.foldername(name))[1]
            AND gm.user_id = auth.uid()
            AND gm.role IN ('admin', 'owner')
        )
    );

-- DELETE: Group admins/owners can delete
CREATE POLICY "group_covers_delete_policy" ON storage.objects
    FOR DELETE USING (
        bucket_id = 'group-covers' 
        AND EXISTS (
            SELECT 1 FROM public.group_members gm
            WHERE gm.group_id::text = (storage.foldername(name))[1]
            AND gm.user_id = auth.uid()
            AND gm.role IN ('admin', 'owner')
        )
    );

-- =====================================================
-- EVENT-COVERS BUCKET POLICIES
-- =====================================================

-- SELECT: Anyone can read event covers (public)
CREATE POLICY "event_covers_select_policy" ON storage.objects
    FOR SELECT USING (bucket_id = 'event-covers');

-- INSERT: Event creators can upload
-- Folder structure: event_id/filename
CREATE POLICY "event_covers_insert_policy" ON storage.objects
    FOR INSERT WITH CHECK (
        bucket_id = 'event-covers' 
        AND EXISTS (
            SELECT 1 FROM public.events e
            WHERE e.id::text = (storage.foldername(name))[1]
            AND e.created_by = auth.uid()
        )
    );

-- UPDATE: Event creators can update
CREATE POLICY "event_covers_update_policy" ON storage.objects
    FOR UPDATE USING (
        bucket_id = 'event-covers' 
        AND EXISTS (
            SELECT 1 FROM public.events e
            WHERE e.id::text = (storage.foldername(name))[1]
            AND e.created_by = auth.uid()
        )
    );

-- DELETE: Event creators can delete
CREATE POLICY "event_covers_delete_policy" ON storage.objects
    FOR DELETE USING (
        bucket_id = 'event-covers' 
        AND EXISTS (
            SELECT 1 FROM public.events e
            WHERE e.id::text = (storage.foldername(name))[1]
            AND e.created_by = auth.uid()
        )
    );

-- =====================================================
-- VISUAL-JOURNAL BUCKET POLICIES
-- =====================================================

-- SELECT: Anyone authenticated can read (public)
CREATE POLICY "visual_journal_select_policy" ON storage.objects
    FOR SELECT USING (
        bucket_id = 'visual-journal' 
        AND auth.uid() IS NOT NULL
    );

-- INSERT: Users can upload to their own folder
CREATE POLICY "visual_journal_insert_policy" ON storage.objects
    FOR INSERT WITH CHECK (
        bucket_id = 'visual-journal' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- UPDATE: Users can update their own uploads
CREATE POLICY "visual_journal_update_policy" ON storage.objects
    FOR UPDATE USING (
        bucket_id = 'visual-journal' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- DELETE: Users can delete their own uploads
CREATE POLICY "visual_journal_delete_policy" ON storage.objects
    FOR DELETE USING (
        bucket_id = 'visual-journal' 
        AND auth.uid()::text = (storage.foldername(name))[1]
    );

-- =====================================================
-- END OF STORAGE BUCKETS AND POLICIES SCRIPT
-- =====================================================
