# Colony App - Supabase Database Schema

This directory contains all SQL scripts for setting up the Colony app database in Supabase.

## 📁 File Structure

```
sql/
├── 01_core_tables.sql      # Tables 1-5: profiles, device_logs, blocked_devices, user_reports, blocked_users
├── 02_social_tables.sql    # Tables 6-14: conversations, messages, groups, events, etc.
├── 03_extended_tables.sql  # Tables 15-29: waves, connections, stories, notifications, achievements, etc.
├── 04_rls_policies.sql     # Row Level Security policies for all tables
├── 05_functions_triggers.sql # SQL functions and triggers
├── 06_realtime.sql         # Realtime configuration
└── README.md               # This file
```

## 🚀 Execution Order

**IMPORTANT:** Execute the SQL files in the following order in the Supabase SQL Editor:

1. `01_core_tables.sql` - Core tables and indexes
2. `02_social_tables.sql` - Social/messaging tables
3. `03_extended_tables.sql` - Extended feature tables + default data
4. `04_rls_policies.sql` - Row Level Security policies
5. `05_functions_triggers.sql` - Functions and triggers
6. `06_realtime.sql` - Realtime configuration

## 📊 Database Schema Overview

### Core Tables (1-5)
| Table | Description |
|-------|-------------|
| `profiles` | User profiles extending auth.users |
| `device_logs` | Device login tracking for security |
| `blocked_devices` | Admin-banned devices |
| `user_reports` | User reports for moderation |
| `blocked_users` | User-level blocking |

### Social Tables (6-14)
| Table | Description |
|-------|-------------|
| `conversations` | Direct and group conversations |
| `conversation_participants` | Users in conversations |
| `messages` | Chat messages with media support |
| `message_reactions` | Emoji reactions on messages |
| `message_read_receipts` | Read status tracking |
| `groups` | Location-based community groups |
| `group_members` | Group membership |
| `events` | Location-based events |
| `event_responses` | Event RSVPs |

### Extended Tables (15-29)
| Table | Description |
|-------|-------------|
| `waves` | Connection requests |
| `connections` | Accepted connections/friendships |
| `stories` | Ephemeral 24-hour stories |
| `story_views` | Story view tracking |
| `notifications` | User notifications |
| `achievements` | Gamification achievements |
| `user_achievements` | User achievement progress |
| `daily_streaks` | Activity streaks |
| `user_subscriptions` | Premium subscriptions |
| `profile_boosts` | Profile visibility boosts |
| `virtual_gifts` | Virtual gifts between users |
| `admin_settings` | Dynamic app configuration |
| `admin_audit_log` | Admin action audit trail |
| `polls` | Location-based polls |
| `poll_votes` | Poll votes |

## 🔐 Security Features

### Row Level Security (RLS)
- All 29 tables have RLS enabled
- Users can only access their own data
- Blocked users cannot see each other
- Admin-only access for sensitive tables

### Helper Functions
- `is_admin(user_id)` - Check admin privileges
- `are_users_blocked(uid1, uid2)` - Check if users blocked each other

## ⚡ Key Functions

| Function | Purpose |
|----------|---------|
| `handle_new_user()` | Auto-create profile on signup |
| `get_nearby_users()` | Find users within radius (Haversine) |
| `get_nearby_events()` | Find events within radius |
| `get_nearby_groups()` | Find groups within radius |
| `accept_wave()` | Accept wave and create connection |
| `update_user_location()` | Update user location |
| `check_device_limit()` | Enforce device account limit |
| `increment_karma()` | Add karma points |
| `check_and_update_streak()` | Update activity streaks |
| `get_user_stats()` | Get user statistics |

## 📡 Realtime Tables

The following tables are enabled for real-time updates:

- `messages` - Real-time chat
- `conversations` - Conversation updates
- `waves` - Wave notifications
- `notifications` - Notification badges
- `profiles` - Online status
- `stories` - New stories
- `message_reactions` - Emoji reactions
- `connections` - Connection updates
- `groups` - Group updates
- `events` - Event updates
- `polls` - Poll updates

## 🎮 Default Data

### Achievements (12 default achievements)
- First Wave, Wave Master, Social Butterfly
- Party Starter, Event Mogul, Hive Builder
- Story Teller, Week Warrior, Monthly Legend
- Colony Pioneer, Night Owl, Early Bird

### Admin Settings (8 default settings)
- Wave limits, nearby radius, group limits
- Story duration, wave expiry, device limits
- Minimum age, maintenance mode

## 📝 Notes

1. **Device Limit**: Maximum 3 accounts per device (configurable via admin_settings)
2. **Wave Expiry**: Waves expire after 24 hours
3. **Story Expiry**: Stories expire after 24 hours
4. **Haversine Formula**: Used for location-based queries (6371km Earth radius)

## 🔄 Migration Strategy

When making schema changes:

1. Create a new migration file: `07_migration_name.sql`
2. Test on a development branch first
3. Apply to production during low-traffic period
4. Update this README with changes

---

**Created for Colony - Location-based Social Community App**
