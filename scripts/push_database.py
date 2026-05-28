#!/usr/bin/env python3
"""
Push database schema to Supabase using REST API
"""

import requests
import json
import time

# Configuration from Flutter app
SUPABASE_URL = "https://pfcqskmitzeclipipvak.supabase.co"
SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBmY3Fza21pdHplY2xpcGlwdmFrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzUyMTI3NjQsImV4cCI6MjA5MDc4ODc2NH0.YY3yWVWAiTadyxiJLrZiO_99ccfmF_Ld-JA2aFXAVGM"

import os

# Read the SQL file
script_dir = os.path.dirname(os.path.abspath(__file__))
sql_path = os.path.join(script_dir, "..", "database", "QUICK_DATABASE_SETUP.sql")
with open(sql_path, 'r', encoding='utf-8') as f:
    sql_content = f.read()

print("=" * 60)
print("🚀 COLONY DATABASE PUSH SCRIPT")
print("=" * 60)
print(f"Supabase URL: {SUPABASE_URL}")
print(f"SQL file size: {len(sql_content)} bytes")
print()

# Split SQL into individual statements
statements = []
current_statement = []

for line in sql_content.split('\n'):
    # Skip empty lines and comments
    line = line.strip()
    if not line or line.startswith('--'):
        continue

    current_statement.append(line)

    # If line ends with semicolon, it's a complete statement
    if line.endswith(';'):
        statements.append(' '.join(current_statement))
        current_statement = []

print(f"📝 Found {len(statements)} SQL statements to execute")
print()

# Execute using Supabase SQL endpoint
headers = {
    "apikey": SUPABASE_ANON_KEY,
    "Authorization": f"Bearer {SUPABASE_ANON_KEY}",
    "Content-Type": "application/json",
    "Prefer": "return=minimal"
}

success_count = 0
error_count = 0

for i, statement in enumerate(statements[:5], 1):  # Test with first 5 statements
    print(f"[{i}/{len(statements)}] Executing: {statement[:80]}...")

    try:
        # Use the query endpoint
        response = requests.post(
            f"{SUPABASE_URL}/rest/v1/rpc/query",
            headers=headers,
            json={"query": statement},
            timeout=30
        )

        if response.status_code in [200, 201, 204]:
            print(f"  ✅ Success")
            success_count += 1
        else:
            print(f"  ⚠️  Status: {response.status_code}")
            print(f"  Response: {response.text[:200]}")
            error_count += 1

    except Exception as e:
        print(f"  ❌ Error: {str(e)[:200]}")
        error_count += 1

    # Small delay between requests
    time.sleep(0.1)

print()
print("=" * 60)
print(f"✅ Successful: {success_count}/{len(statements[:5])}")
print(f"❌ Errors: {error_count}/{len(statements[:5])}")
print("=" * 60)
print()
print("⚠️  Note: This script has limitations applying DDL via REST API.")
print("Please use the Supabase Dashboard SQL Editor for full schema setup.")
print()
print("📋 Instructions:")
print("1. Go to: https://supabase.com/dashboard/project/pfcqskmitzeclipipvak/sql")
print("2. Copy the content from: QUICK_DATABASE_SETUP.sql")
print("3. Paste in SQL Editor and click 'Run'")
print("=" * 60)
