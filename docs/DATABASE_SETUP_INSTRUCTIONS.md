# 🚀 Colony App - Database Setup Instructions

## ✅ Code Changes Pushed to GitHub!
All Flutter code fixes have been committed and pushed to:
- **Repository:** https://github.com/devamsshinde/colony-app
- **Commit:** 435613c

---

## 📊 Next Step: Setup Supabase Database

Since the Supabase CLI has network connectivity issues, follow these steps to set up your database:

### Method 1: Using Supabase Dashboard (Recommended)

1. **Open Your Supabase Project:**
   - Go to: https://supabase.com/dashboard/project/pfcqskmitzeclipipvak

2. **Open SQL Editor:**
   - Left sidebar → **SQL Editor**
   - Click **"New Query"**

3. **Copy and Paste:**
   - Open the file: `backend/database/QUICK_DATABASE_SETUP.sql`
   - Copy the **ENTIRE content**
   - Paste it into the SQL Editor

4. **Execute:**
   - Click **"Run"** (or press `Ctrl+Enter`)
   - Wait for the script to complete (should see "✅ COLONY DATABASE SETUP COMPLETE!")

5. **Reload Schema Cache:**
   - Go to: Settings → API
   - Scroll down to "Schema Cache"
   - Click **"Reload Schema Cache"**
   - Wait 10-30 seconds

---

### Method 2: Using Supabase CLI (If Network Allows)

If the CLI connection issues resolve, you can run:

```bash
./backend/bin/supabase.exe db push
```

However, the Dashboard method is more reliable.

---

## 🧪 Verify the Setup

After running the SQL script, verify by checking:

1. **Table Editor:**
   - Go to: Table Editor
   - You should see all tables: `profiles`, `waves`, `connections`, `groups`, `events`, `stories`, etc.

2. **Check Profiles Table Structure:**
   - Click on `profiles` table
   - Verify it has these columns:
     - ✅ `location_name` (not `location`)
     - ✅ `onboarding_completed`
     - ✅ `latitude`, `longitude`
     - ✅ `is_online`, `last_seen`

3. **Test SQL Query:**
   - In SQL Editor, run:
   ```sql
   SELECT column_name, data_type
   FROM information_schema.columns
   WHERE table_schema = 'public' AND table_name = 'profiles'
   ORDER BY ordinal_position;
   ```
   - You should see `location_name` in the results

---

## 📱 Test the Flutter App

1. **Run the app:**
   ```bash
   cd frontend
   flutter run
   ```

2. **Complete Onboarding:**
   - Step 1: Welcome
   - Step 2: Profile Setup (name, username, bio, DOB, gender)
   - Step 3: Interests (select 3+)
   - Step 4: Location Permission (grant it)
   - Step 5: Click "Start Exploring"

3. **Expected Result:**
   - ✅ Should save successfully without errors
   - ✅ Navigate to home screen
   - ✅ Show location loading screen briefly
   - ✅ Display home screen with nearby users

---

## 🔍 Debug Mode

If you encounter issues, check the console logs. You should see:

```
🔄 Starting onboarding completion...
📊 Save result: true, onboardingComplete: true
✅ Onboarding saved successfully! Popping to AuthWrapper...
🔍 Checking onboarding status for user: [user-id]
📊 Onboarding status from DB: true
✅ User has completed onboarding, starting location fetching...
```

If you see errors, copy them and share for troubleshooting.

---

## 🎯 What Was Fixed

1. ✅ Changed `'location'` to `'location_name'` in Flutter code
2. ✅ Fixed onboarding navigation flow
3. ✅ Added debug logging
4. ✅ Enhanced AuthWrapper to re-check onboarding status
5. ✅ All code pushed to GitHub

---

## 📞 Need Help?

If you encounter any errors:
1. Copy the exact error message
2. Share the console logs
3. Check Supabase Dashboard → Table Editor → verify `profiles` table exists

---

**Your Colony app should now work correctly! 🎉**
