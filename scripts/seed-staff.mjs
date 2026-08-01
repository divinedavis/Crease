#!/usr/bin/env node
/**
 * Create a portal login for a cleaner's staff.
 *
 *   node scripts/seed-staff.mjs <cleaner-slug> <email> [password] [role]
 *
 * Shops do not self-register — we onboard them — so this is the intended
 * path to a portal account, not just a test fixture.
 */
import { createClient } from '@supabase/supabase-js';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const env = Object.fromEntries(
  readFileSync(join(root, 'services/dispatch/.env'), 'utf8')
    .split('\n')
    .filter((l) => l.includes('=') && !l.startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1)]),
);

const [slug, email, password = 'crease-dev-password', role = 'owner'] = process.argv.slice(2);
if (!slug || !email) {
  console.error('usage: node scripts/seed-staff.mjs <cleaner-slug> <email> [password] [role]');
  process.exit(1);
}

const db = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false },
});

const { data: cleaner, error: cErr } = await db
  .from('cleaners')
  .select('id, name')
  .eq('slug', slug)
  .single();
if (cErr || !cleaner) throw new Error(`no cleaner with slug '${slug}'`);

const { data: list } = await db.auth.admin.listUsers();
let user = list.users.find((u) => u.email === email);
if (!user) {
  const { data, error } = await db.auth.admin.createUser({
    email,
    password,
    email_confirm: true, // no verification step, per product rule
    user_metadata: { full_name: `${cleaner.name} staff` },
  });
  if (error) throw error;
  user = data.user;
} else {
  await db.auth.admin.updateUserById(user.id, { password });
}

const { error } = await db
  .from('cleaner_staff')
  .upsert({ cleaner_id: cleaner.id, user_id: user.id, role }, { onConflict: 'cleaner_id,user_id' });
if (error) throw error;

console.log(`${email} -> ${cleaner.name} (${role})`);
