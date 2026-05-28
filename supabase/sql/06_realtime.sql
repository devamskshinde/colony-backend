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
