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
