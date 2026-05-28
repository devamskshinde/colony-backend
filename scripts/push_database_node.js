const { createClient } = require('@supabase/supabase-js');
const fs = require('fs');

// Configuration
const SUPABASE_URL = 'https://pfcqskmitzeclipipvak.supabase.co';
const SUPABASE_SERVICE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InBmY3Fza21pdHplY2xpcGlwdmFrIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc3NTIxMjc2NCwiZXhwIjoyMDkwNzg4NzY0fQ.YY3yWVWAiTadyxiJLrZiO_99ccfmF_Ld-JA2aFXAVGM';

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
  auth: {
    autoRefreshToken: false,
    persistSession: false
  }
});

async function executeSQL(sql) {
  try {
    const { data, error } = await supabase.rpc('exec_sql', { sql_query: sql });
    if (error) {
      // If exec_sql function doesn't exist, we need to use direct SQL
      console.log('exec_sql function not found, trying alternative method...');
      console.log('Error:', error.message);
      return false;
    }
    return true;
  } catch (err) {
    console.error('Exception:', err.message);
    return false;
  }
}

const path = require('path');

async function createTableViaAPI() {
  const sqlPath = path.join(__dirname, '..', 'database', 'QUICK_DATABASE_SETUP.sql');
  const sqlContent = fs.readFileSync(sqlPath, 'utf8');

  console.log('='.repeat(60));
  console.log('🚀 Pushing database schema to Supabase...');
  console.log('='.repeat(60));

  // Split into statements
  const statements = sqlContent
    .split(';')
    .map(s => s.trim())
    .filter(s => s.length > 0 && !s.startsWith('--'));

  console.log(`Found ${statements.length} SQL statements`);

  let success = 0;
  let failed = 0;

  for (let i = 0; i < Math.min(5, statements.length); i++) {
    const stmt = statements[i];
    console.log(`\n[${i + 1}/${statements.length}] Executing: ${stmt.substring(0, 80)}...`);

    const result = await executeSQL(stmt + ';');
    if (result) {
      console.log('  ✅ Success');
      success++;
    } else {
      console.log('  ⚠️  Skipped');
      failed++;
    }
  }

  console.log('\n' + '='.repeat(60));
  console.log(`✅ Successful: ${success}`);
  console.log(`⚠️  Skipped: ${failed}`);
  console.log('='.repeat(60));
}

// Alternative: Use PostgREST to create tables
async function createProfilesTable() {
  console.log('\n🔧 Creating profiles table via PostgREST...');

  // Try to create table using direct REST API
  const tableDefinition = {
    id: 'uuid PRIMARY KEY DEFAULT gen_random_uuid()',
    email: 'text UNIQUE NOT NULL',
    username: 'text UNIQUE NOT NULL',
    full_name: 'text NOT NULL',
    location_name: 'text',
    onboarding_completed: 'boolean DEFAULT false',
    latitude: 'double precision',
    longitude: 'double precision',
    is_online: 'boolean DEFAULT false',
    created_at: 'timestamptz DEFAULT now()'
};

  // PostgREST doesn't support DDL, so we need SQL
  console.log('\n❌ PostgREST does not support DDL operations (CREATE TABLE)');
  console.log('✅ You MUST use Supabase Dashboard SQL Editor');
  console.log('\n📋 Instructions:');
  console.log('1. Open: QUICK_DATABASE_SETUP.sql');
  console.log('2. Copy the entire content (Ctrl+A, Ctrl+C)');
  console.log('3. Go to: https://supabase.com/dashboard/project/pfcqskmitzeclipipvak/sql');
  console.log('4. Paste in SQL Editor');
  console.log('5. Click "Run" button');
  console.log('6. Wait for success message');
  console.log('\n✅ This will set up your complete database schema!');
}

createProfilesTable();
